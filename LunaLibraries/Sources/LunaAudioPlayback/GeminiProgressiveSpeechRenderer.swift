import AVFoundation
import Foundation

/// One-second pulls let the existing engine bound its lookahead. The session ID
/// invalidates an in-flight pull on seek, pause/restart or article replacement.
protocol ProgressiveSpeechRendering: SpeechRendering {
    func nextSegment(startingAt block: AudioScript.SpokenBlock, sessionID: UUID) async throws -> RenderedSegment?
}

/// Disk-backed PCM avoids retaining an entire article while generation runs
/// ahead of listening. These files are private temporary transport buffers;
/// only validated, finalized AAC files enter the durable shared cache.
final class GeminiSpeechSpool: @unchecked Sendable {
    struct Snapshot { let bytes: Int; let complete: Bool; let error: Error? }
    private let lock = NSLock()
    private let directory: URL
    private var sizes: [Int]
    private var completed: Set<Int> = []
    private var failure: Error?
    private var fraction: Double = 0
    private var progressHandlers: [(Double) -> Void] = []
    init(count: Int) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("GeminiPCM-" + UUID().uuidString, isDirectory: true)
        sizes = Array(repeating: 0, count: count)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    private func url(_ chunk: Int) -> URL { directory.appendingPathComponent("\(chunk).pcm") }
    func append(_ data: Data, chunk: Int) throws {
        lock.lock(); defer { lock.unlock() }
        guard sizes[chunk] + data.count <= 64 * 1_024 * 1_024 else { throw GeminiSpeechError.invalidAudio }
        let url = url(chunk)
        if sizes[chunk] == 0 { FileManager.default.createFile(atPath: url.path, contents: nil) }
        let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: data)
        sizes[chunk] += data.count
    }
    func snapshot(_ chunk: Int) -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(bytes: sizes[chunk], complete: completed.contains(chunk), error: failure)
    }
    func data(_ chunk: Int, offset: Int = 0, count: Int? = nil) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url(chunk)); defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: count ?? 64 * 1_024 * 1_024) ?? Data()
    }
    func complete(_ chunk: Int) { lock.lock(); completed.insert(chunk); lock.unlock() }
    func fail(_ error: Error) { lock.lock(); failure = error; progressHandlers = []; lock.unlock() }
    func observeProgress(_ report: @escaping (Double) -> Void) {
        lock.lock()
        let value = fraction
        if value < 1, failure == nil { progressHandlers.append(report) }
        lock.unlock()
        report(value)
    }
    func reportProgress(_ value: Double) {
        lock.lock()
        guard value > fraction else { lock.unlock(); return }
        fraction = min(1, value)
        let handlers = progressHandlers, current = fraction
        if current == 1 { progressHandlers = [] }
        lock.unlock()
        handlers.forEach { $0(current) }
    }
}

actor GeminiProgressiveSpeechRenderer: ProgressiveSpeechRendering {
    nonisolated let canonicalFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)
    private let folder: URL
    private let plan: GeminiSpeechPlan
    private let live: GeminiSpeechSpool
    private let task: Task<URL, Error>
    private var sessionID: UUID?
    private var chunk = 0
    private var frame = 0
    private var seekRange: NSRange?
    private var lastTextOffset = 0

    init(folder: URL, plan: GeminiSpeechPlan, live: GeminiSpeechSpool, task: Task<URL, Error>) {
        self.folder = folder; self.plan = plan; self.live = live; self.task = task
    }
    func ready() async throws {
        while live.snapshot(0).bytes < 2 && !GeminiArticleSpeech.isPlayable(folder.appendingPathComponent("0.m4a")) {
            try Task.checkCancellation()
            if let error = live.snapshot(0).error { throw error }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    // Exports/tests retain paragraph-relative seeking, through the same cache.
    func render(_ block: AudioScript.SpokenBlock) async throws -> RenderedSegment {
        guard let range = plan.blockRanges[block.blockIndex] else { throw GeminiSpeechError.invalidAudio }
        for (index, chunkRange) in plan.chunkRanges.enumerated() where NSIntersectionRange(range, chunkRange).length > 0 {
            while !GeminiArticleSpeech.isPlayable(folder.appendingPathComponent("\(index).m4a")) {
                try Task.checkCancellation()
                if let error = live.snapshot(index).error { throw error }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        return try await GeminiCachedSpeechRenderer(folder: folder, plan: plan).render(block)
    }
    func nextSegment(startingAt block: AudioScript.SpokenBlock, sessionID token: UUID) async throws -> RenderedSegment? {
        if sessionID != token {
            guard let range = plan.blockRanges[block.blockIndex],
                  let index = plan.chunkRanges.firstIndex(where: { NSIntersectionRange($0, range).length > 0 }) else {
                throw GeminiSpeechError.invalidAudio
            }
            sessionID = token; chunk = index; frame = 0
            lastTextOffset = range.location
            seekRange = range.location > plan.chunkRanges[index].location ? range : nil
        }
        while chunk < plan.chunks.count {
            try Task.checkCancellation()
            guard sessionID == token else { throw CancellationError() }
            let snapshot = live.snapshot(chunk)
            if let error = snapshot.error { throw error }
            let fileURL = folder.appendingPathComponent("\(chunk).m4a")
            let cached = GeminiArticleSpeech.isPlayable(fileURL)
            // A proportional seek needs the final duration. Fresh playback can
            // consume the first PCM frames immediately, before any chunk closes.
            if seekRange != nil && !snapshot.complete && !cached {
                try await Task.sleep(nanoseconds: 50_000_000); continue
            }
            let source: AVAudioFile? = snapshot.bytes == 0 && cached ? try AVAudioFile(forReading: fileURL) : nil
            let total = source.map { Int($0.length) } ?? snapshot.bytes / 2
            if let seekRange {
                let range = plan.chunkRanges[chunk]
                frame = Int(Double(seekRange.location - range.location) / Double(range.length) * Double(total))
                self.seekRange = nil
            }
            let count = min(24_000, total - frame)
            if count > 0 {
                guard let target = canonicalFormat else { throw GeminiSpeechError.invalidAudio }
                let buffers: [AVAudioPCMBuffer]
                if let source {
                    source.framePosition = AVAudioFramePosition(frame)
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: source.processingFormat, frameCapacity: AVAudioFrameCount(count)) else { throw GeminiSpeechError.invalidAudio }
                    try source.read(into: buffer, frameCount: AVAudioFrameCount(count))
                    guard buffer.frameLength == count else { throw GeminiSpeechError.invalidAudio }
                    buffers = try AudioFormatConversion.convert([buffer], from: source.processingFormat, to: target)
                } else {
                    let data = try live.data(chunk, offset: frame * 2, count: count * 2)
                    guard data.count == count * 2,
                          let buffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(count)),
                          let samples = buffer.floatChannelData?[0] else { throw GeminiSpeechError.invalidAudio }
                    buffer.frameLength = AVAudioFrameCount(count)
                    data.withUnsafeBytes { bytes in
                        for index in 0..<count {
                            let value = bytes.loadUnaligned(fromByteOffset: index * 2, as: Int16.self)
                            samples[index] = Float(Int16(littleEndian: value)) / 32768
                        }
                    }
                    buffers = [buffer]
                }
                // Google supplies no timestamps; text position is approximate.
                // Frame cursors, however, are exact, so no audio is skipped or repeated.
                let expectedFrames = snapshot.complete || cached ? max(1, total) : max(total + 1, Int(Double(AudioWordIndexing.wordCount(in: plan.chunks[chunk])) / 170 * 60 * 24_000))
                let range = plan.chunkRanges[chunk]
                let textOffset = max(lastTextOffset, range.location + min(range.length - 1, Int(Double(frame) / Double(expectedFrames) * Double(range.length))))
                lastTextOffset = textOffset
                let blockIndex = plan.blockRanges.first(where: { NSLocationInRange(textOffset, $0.value) })?.key ?? block.blockIndex
                frame += count
                return RenderedSegment(blockIndex: blockIndex, buffers: buffers, wordMarkers: [], duration: Double(count) / 24_000, format: target)
            }
            if snapshot.complete || cached {
                chunk += 1; frame = 0
            } else { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        // Even when the final PCM has played, provider completion and AAC
        // validation must succeed before the article may be marked finished.
        _ = try await task.value
        guard sessionID == token else { throw CancellationError() }
        return nil
    }
}
