import Foundation

/// Raw deltas survive every transport/provider failure and process termination.
/// The small atomic manifest records which prefix has already been aligned;
/// bytes after it are pending audio, never a completed chunk cache entry.
final class GeminiSpeechPartial {
    private struct Manifest: Codable {
        var boundaries: [GeminiSpeechAlignment.Boundary] = []
    }
    private let pcmURL: URL
    private let manifestURL: URL
    private var manifest: Manifest
    private(set) var bytes: Int
    var boundary: GeminiSpeechAlignment.Boundary {
        manifest.boundaries.last ?? .init(textEnd: 0, frames: 0)
    }
    var boundaries: [GeminiSpeechAlignment.Boundary] { manifest.boundaries }

    init(folder: URL, chunk: Int, text: String) throws {
        pcmURL = folder.appendingPathComponent("\(chunk).partial.pcm")
        manifestURL = folder.appendingPathComponent("\(chunk).partial.json")
        manifest = (try? JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))) ?? Manifest()
        bytes = (try? pcmURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let ends = Set(GeminiSpeechSentences.ranges(in: text).map(NSMaxRange))
        var previous = GeminiSpeechAlignment.Boundary(textEnd: 0, frames: 0)
        let valid = manifest.boundaries.allSatisfy { current in
            defer { previous = current }
            return ends.contains(current.textEnd) && current.textEnd > previous.textEnd && current.frames > previous.frames && current.frames <= bytes / 2
        }
        if !valid || bytes > 64 * 1_024 * 1_024 {
            manifest = Manifest(); bytes = 0
            try Data().write(to: pcmURL, options: .atomic)
        }
    }

    func recover(text: String, recognize: @escaping GeminiSpeechAlignment.Recognize) async throws -> Data {
        let old = boundary
        let evenBytes = bytes - bytes % 2
        if evenBytes > old.frames * 2 {
            let source = try FileHandle(forReadingFrom: pcmURL)
            defer { try? source.close() }
            try source.seek(toOffset: UInt64(old.frames * 2))
            let pending = try source.read(upToCount: evenBytes - old.frames * 2) ?? Data()
            let suffix = (text as NSString).substring(from: old.textEnd)
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            try GeminiArticleSpeech.wav(fromPCM: pending).write(to: wav, options: .atomic)
            do {
                let spans = try await GeminiSpeechAlignment.measure(wav, text: suffix, recognize: recognize)
                let aligned = GeminiSpeechAlignment.boundaries(text: suffix, spans: spans, frames: pending.count / 2)
                // An interrupted request cannot certify its final sentence, even
                // if the recognizer guessed all its words from clipped audio.
                manifest.boundaries += aligned.filter { $0.textEnd < suffix.utf16.count }.map {
                    .init(textEnd: old.textEnd + $0.textEnd, frames: old.frames + $0.frames)
                }
            } catch {
                try Task.checkCancellation()
                // Keep the previously certified prefix when recognition is
                // unavailable. No failure is allowed to skip unconfirmed text.
            }
        }
        try Task.checkCancellation()
        let keep = boundary.frames * 2
        // Publish metadata first: if killed between these operations, the new
        // prefix is still valid in the longer PCM file on the next attempt.
        try JSONEncoder().encode(manifest).write(to: manifestURL, options: .atomic)
        if !FileManager.default.fileExists(atPath: pcmURL.path) { try Data().write(to: pcmURL) }
        let handle = try FileHandle(forWritingTo: pcmURL)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(keep))
        bytes = keep
        return try Data(contentsOf: pcmURL)
    }

    func append(_ data: Data) throws {
        guard bytes + data.count <= 64 * 1_024 * 1_024 else { throw GeminiSpeechError.invalidAudio }
        let handle = try FileHandle(forWritingTo: pcmURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        bytes += data.count
    }

    func remove() {
        try? FileManager.default.removeItem(at: pcmURL)
        try? FileManager.default.removeItem(at: manifestURL)
    }
}
