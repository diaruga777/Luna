import AVFoundation
import CryptoKit
import Foundation
import LunaModels
import LunaAppConfig
import LunaStorage

public enum GeminiSpeechCredential {
    private static var service: String { AppConfig.appGroupID + ".gemini-speech" }
    public static var apiKey: String? {
        get { CredentialKeychain.read(service: service, account: "api-key") }
        set {
            let key = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            CredentialKeychain.write(key, service: service, account: "api-key")
        }
    }
}

enum GeminiSpeechError: LocalizedError {
    case missingKey, quota, unauthorized, unavailable, invalidAudio, incomplete
    var errorDescription: String? {
        switch self {
        case .missingKey: return L10n.string("Gemini_missingKey")
        case .quota: return L10n.string("Gemini_quota")
        case .unauthorized: return L10n.string("Gemini_unauthorized")
        case .unavailable: return L10n.string("Gemini_unavailable")
        case .invalidAudio: return L10n.string("Gemini_invalidAudio")
        case .incomplete: return L10n.string("Gemini_incomplete")
        }
    }
}

/// Bounded requests preserve all text, including scripts without whitespace.
/// Every chunk is cached independently so a quota failure never discards earlier work.
struct GeminiSpeechPlan {
    let chunks: [String]
    let blockRanges: [Int: NSRange]
    let chunkRanges: [NSRange]
    let fingerprint: String

    init(script: AudioScript) {
        var text = ""
        var ranges: [Int: NSRange] = [:]
        var previousBlock: Int?
        for block in script.spokenBlocks {
            let body = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            if let previousBlock {
                text += "\n\n"
                ranges[previousBlock]!.length += 2
            }
            let start = text.utf16.count
            text += body
            ranges[block.blockIndex] = NSRange(location: start, length: text.utf16.count - start)
            previousBlock = block.blockIndex
        }
        var chunks: [String] = []
        var chunk = ""
        var bytes = 0
        var words = 0
        var previousWhitespace = true
        for character in text {
            let newWord = previousWhitespace && !character.isWhitespace
            let size = String(character).utf8.count
            if !chunk.isEmpty && (bytes + size > 7_500 || (newWord && words >= 1_200)) {
                if let boundary = chunk.lastIndex(where: { $0.isWhitespace }),
                   chunk.distance(from: boundary, to: chunk.endIndex) < 100,
                   !chunk[..<boundary].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let end = chunk.index(after: boundary)
                    chunks.append(String(chunk[..<end]))
                    chunk = String(chunk[end...])
                    bytes = chunk.utf8.count
                    words = AudioWordIndexing.wordCount(in: chunk)
                } else {
                    chunks.append(chunk)
                    chunk = ""; bytes = 0; words = 0
                }
            }
            chunk.append(character)
            bytes += size
            if newWord { words += 1 }
            previousWhitespace = character.isWhitespace
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        var offset = 0
        self.chunkRanges = chunks.map {
            defer { offset += $0.utf16.count }
            return NSRange(location: offset, length: $0.utf16.count)
        }
        self.chunks = chunks
        self.blockRanges = ranges
        // Include block boundaries, voice, model and cache schema, but never the API key.
        let identity = "v2-aac|gemini-3.8-flash-tts|Kore|" + String(describing: script.spokenBlocks.map { $0.blockIndex }) + text
        self.fingerprint = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// Only Reader's playback composition installs this provider. No ingest sweep,
/// extension, autoplay miss or Music export can spend the user's speech quota.
public actor GeminiArticleSpeech {
    public static let shared = GeminiArticleSpeech()
    static let model = "gemini-3.8-flash-tts"
    private let directory: URL
    private let send: (URLRequest) async throws -> (Data, URLResponse)
    private var pending: [String: (id: UUID, task: Task<URL, Error>)] = [:]
    private let apiKey: () -> String?

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GeminiArticleSpeech", isDirectory: true)
        let session = URLSession(configuration: .ephemeral)
        self.send = { try await session.data(for: $0) }
        self.apiKey = { GeminiSpeechCredential.apiKey }
    }

    init(directory: URL, apiKey: @escaping () -> String? = { "test-key" }, send: @escaping (URLRequest) async throws -> (Data, URLResponse)) {
        self.directory = directory
        self.send = send
        self.apiKey = apiKey
    }

    public func renderer(itemID: UUID, script: AudioScript, allowGeneration: Bool) async throws -> SpeechRendering? {
        let plan = GeminiSpeechPlan(script: script)
        guard !plan.chunks.isEmpty else { throw GeminiSpeechError.incomplete }
        let key = itemID.uuidString + "/" + plan.fingerprint
        let folder = directory.appendingPathComponent(key, isDirectory: true)
        if Self.isComplete(folder, count: plan.chunks.count) {
            return try GeminiCachedSpeechRenderer(folder: folder, plan: plan)
        }
        guard allowGeneration else { return nil }
        if let operation = pending[key] {
            return try GeminiCachedSpeechRenderer(folder: await operation.task.value, plan: plan)
        }
        guard let apiKey = apiKey(), !apiKey.isEmpty else { throw GeminiSpeechError.missingKey }
        let send = self.send
        let task = Task<URL, Error> {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            BackupPolicy.excludeFromBackups(folder)
            for (index, text) in plan.chunks.enumerated() {
                try Task.checkCancellation()
                let file = folder.appendingPathComponent("\(index).m4a")
                if Self.isPlayable(file) { continue }
                let request = try Self.request(text: text, apiKey: apiKey)
                let (data, response) = try await send(request)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { throw GeminiSpeechError.unavailable }
                switch http.statusCode {
                case 200..<300: break
                case 401, 403: throw GeminiSpeechError.unauthorized
                case 429: throw GeminiSpeechError.quota
                default: throw GeminiSpeechError.unavailable
                }
                let audio = try Self.audio(from: data)
                try Self.cacheAudio(audio, at: file)
                guard Self.isPlayable(file) else {
                    try? FileManager.default.removeItem(at: file)
                    throw GeminiSpeechError.invalidAudio
                }
            }
            return folder
        }
        let operationID = UUID()
        pending[key] = (operationID, task)
        defer { if pending[key]?.id == operationID { pending[key] = nil } }
        return try GeminiCachedSpeechRenderer(folder: await task.value, plan: plan)
    }

    public func clearCache() throws {
        for operation in pending.values { operation.task.cancel() }
        pending.removeAll()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    /// Called on saves changes so deleting an article also removes its generated audio.
    public func removeAudio(except itemIDs: Set<UUID>) throws {
        let names = Set(itemIDs.map { $0.uuidString })
        for key in Array(pending.keys) where !names.contains(String(key.prefix(36))) {
            pending.removeValue(forKey: key)?.task.cancel()
        }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for folder in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where !names.contains(folder.lastPathComponent) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    static func request(text: String, apiKey: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 240
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model,
            "store": false,
            "input": [["type": "user_input", "content": [["type": "text", "text": text]]]],
            "response_format": ["type": "audio", "mime_type": "audio/wav"],
            "generation_config": ["max_output_tokens": 16_384, "speech_config": [["voice": "Kore"]]],
        ])
        return request
    }

    static func audio(from data: Data) throws -> Data {
        struct Response: Decodable {
            struct Step: Decodable {
                struct Content: Decodable { let type: String; let data: String?; let mime_type: String? }
                let type: String
                let content: [Content]?
            }
            let status: String
            let steps: [Step]?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.status == "completed" else {
            throw GeminiSpeechError.incomplete
        }
        let parts = (response.steps ?? []).filter { $0.type == "model_output" }.flatMap { $0.content ?? [] }.filter { $0.type == "audio" }
        // Unary TTS returns one complete WAV. Reject unexpected multipart output rather than truncating it.
        guard parts.count == 1, parts[0].mime_type == "audio/wav", let encoded = parts[0].data,
              let audio = Data(base64Encoded: encoded), audio.count > 44,
              String(data: audio.prefix(4), encoding: .ascii) == "RIFF",
              String(data: audio[8..<12], encoding: .ascii) == "WAVE"
        else { throw GeminiSpeechError.invalidAudio }
        return audio
    }

    /// AAC keeps a library of readouts small. Publish only a finalized container;
    /// temporary response/audio files are removed on both success and failure.
    private static func cacheAudio(_ data: Data, at destination: URL) throws {
        let folder = destination.deletingLastPathComponent()
        let source = folder.appendingPathComponent(UUID().uuidString + ".wav")
        let staging = folder.appendingPathComponent(UUID().uuidString + ".m4a")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: staging)
        }
        try data.write(to: source, options: .atomic)
        let input = try AVAudioFile(forReading: source)
        let format = input.processingFormat
        guard input.length > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)
        else { throw GeminiSpeechError.invalidAudio }
        var output: AVAudioFile? = try AVAudioFile(forWriting: staging, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 64_000,
        ])
        while input.framePosition < input.length {
            try Task.checkCancellation()
            try input.read(into: buffer)
            guard buffer.frameLength > 0 else { throw GeminiSpeechError.invalidAudio }
            try output?.write(from: buffer)
        }
        output = nil
        try Task.checkCancellation()
        // The destination may contain a corrupt old entry; replacement is local
        // and there is only one generation operation for this article identity.
        if FileManager.default.fileExists(atPath: destination.path) {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: destination)
        }
    }

    private static func isComplete(_ folder: URL, count: Int) -> Bool {
        (0..<count).allSatisfy { isPlayable(folder.appendingPathComponent("\($0).m4a")) }
    }
    private static func isPlayable(_ url: URL) -> Bool {
        guard let file = try? AVAudioFile(forReading: url) else { return false }
        return file.length > 0 && file.processingFormat.sampleRate > 0
    }
}

/// Google supplies no alignment timestamps. Paragraph seeking uses proportional
/// text offsets; forward playback includes every frame exactly once. Never invent
/// word events that would imply accurate RSVP synchronization.
final class GeminiCachedSpeechRenderer: SpeechRendering {
    let canonicalFormat: AVAudioFormat? = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false)
    private let folder: URL
    private let plan: GeminiSpeechPlan
    init(folder: URL, plan: GeminiSpeechPlan) throws {
        self.folder = folder
        self.plan = plan
    }
    func render(_ block: AudioScript.SpokenBlock) async throws -> RenderedSegment {
        guard let range = plan.blockRanges[block.blockIndex], let target = canonicalFormat else { throw GeminiSpeechError.invalidAudio }
        var buffers: [AVAudioPCMBuffer] = []
        for (index, chunkRange) in plan.chunkRanges.enumerated() {
            let intersection = NSIntersectionRange(range, chunkRange)
            guard intersection.length > 0 else { continue }
            let file = try AVAudioFile(forReading: folder.appendingPathComponent("\(index).m4a"))
            let start = AVAudioFramePosition(Double(intersection.location - chunkRange.location) / Double(chunkRange.length) * Double(file.length))
            let end = AVAudioFramePosition(Double(NSMaxRange(intersection) - chunkRange.location) / Double(chunkRange.length) * Double(file.length))
            file.framePosition = start
            var remaining = end - start
            while remaining > 0 {
                try Task.checkCancellation()
                let count = AVAudioFrameCount(min(remaining, 48_000))
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { throw GeminiSpeechError.invalidAudio }
                try file.read(into: buffer, frameCount: count)
                guard buffer.frameLength > 0 else { throw GeminiSpeechError.invalidAudio }
                remaining -= AVAudioFramePosition(buffer.frameLength)
                buffers += try AudioFormatConversion.convert([buffer], from: file.processingFormat, to: target)
            }
        }
        let duration = buffers.reduce(0) { $0 + Double($1.frameLength) / target.sampleRate }
        return RenderedSegment(blockIndex: block.blockIndex, buffers: buffers, wordMarkers: [], duration: duration, format: target)
    }
}
