import Foundation
import CryptoKit

/// Incremental SSE framing. A closed socket is not evidence of a complete readout.
/// Parsing bytes as UTF-8 lines also handles CRLF and non-ASCII server metadata.
struct GeminiSpeechEvents {
    private var dataLines: [String] = []
    private var eventBytes = 0
    private var eventID: String?
    private var seenEvents: [String: SHA256.Digest] = [:]
    private(set) var completed = false
    private(set) var audioBytes = 0

    mutating func line(_ line: String, receive: (Data) throws -> Void) throws {
        guard !line.isEmpty else { try dispatch(receive: receive); return }
        if line.hasPrefix("id:") { eventID = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces); return }
        guard line.hasPrefix("data:") else { return }
        var value = String(line.dropFirst(5))
        if value.first == " " { value.removeFirst() }
        eventBytes += value.utf8.count
        guard eventBytes <= 8 * 1_024 * 1_024 else { throw GeminiSpeechError.invalidAudio }
        dataLines.append(value)
    }

    mutating func finish(receive: (Data) throws -> Void) throws {
        try dispatch(receive: receive)
        guard completed, audioBytes > 0, audioBytes.isMultiple(of: 2) else { throw GeminiSpeechError.incomplete }
    }

    private mutating func dispatch(receive: (Data) throws -> Void) throws {
        guard !dataLines.isEmpty else { return }
        let data = Data(dataLines.joined(separator: "\n").utf8)
        let framingID = eventID
        eventID = nil
        dataLines = []; eventBytes = 0
        guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = event["event_type"] as? String else { throw GeminiSpeechError.incomplete }
        if let id = event["event_id"] as? String ?? framingID, !id.isEmpty {
            let digest = SHA256.hash(data: data)
            if let previous = seenEvents[id] {
                guard previous == digest else { throw GeminiSpeechError.incomplete }
                return // A replayed event must never append its PCM twice.
            }
            guard seenEvents.count < 100_000 else { throw GeminiSpeechError.invalidAudio }
            seenEvents[id] = digest
        }
        if type == "error" || event["error"] != nil {
            throw GeminiArticleSpeech.speechError(statusCode: 500, apiCode: GeminiArticleSpeech.apiErrorCode(from: data))
        }
        if type == "interaction.completed" || type == "interaction.status_update" {
            let interaction = event["interaction"] as? [String: Any] ?? event
            let status = interaction["status"] as? String
            if let errors = interaction["errors"] as? [[String: Any]], !errors.isEmpty { throw GeminiSpeechError.incomplete }
            if status == "completed" { completed = true }
            else if status != "in_progress" { throw GeminiSpeechError.incomplete }
        }
        guard type == "step.delta" else { return }
        guard !completed, let delta = event["delta"] as? [String: Any], delta["type"] as? String == "audio",
              let encoded = delta["data"] as? String, let audio = Data(base64Encoded: encoded), !audio.isEmpty else {
            throw GeminiSpeechError.invalidAudio
        }
        if let mime = delta["mime_type"] as? String {
            let normalized = mime.lowercased().replacingOccurrences(of: " ", with: "")
            guard normalized == "audio/l16" || normalized == "audio/l16;codec=pcm;rate=24000" else { throw GeminiSpeechError.invalidAudio }
        }
        if let rate = delta["sample_rate"] as? Int, rate != 24_000 { throw GeminiSpeechError.invalidAudio }
        audioBytes += audio.count
        guard audioBytes <= 64 * 1_024 * 1_024 else { throw GeminiSpeechError.invalidAudio }
        try receive(audio)
    }
}

struct GeminiSpeechQuotaFailure: Error {
    let retryAt: Date
}

/// Shared by generation tasks. A new credential gets an independent cooldown;
/// no credential or server-provided message is persisted or logged.
final class GeminiSpeechModelAvailability: @unchecked Sendable {
    private let lock = NSLock()
    private var cooldowns: [String: Date] = [:]
    func available(_ model: String, credential: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return (cooldowns[credential + model] ?? .distantPast) <= now
    }
    func suspend(_ model: String, credential: String, until: Date) {
        lock.lock(); defer { lock.unlock() }
        cooldowns[credential + model] = until
    }

    static func retryDate(body: Data, response: HTTPURLResponse, now: Date = Date()) -> Date {
        let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let error = root?["error"] as? [String: Any]
        let details = error?["details"] as? [[String: Any]] ?? []
        let metrics = details.flatMap { $0["violations"] as? [[String: Any]] ?? [] }.flatMap { violation in
            [violation["quotaMetric"] as? String, violation["quotaId"] as? String].compactMap { $0 }
        }
        if metrics.contains(where: { $0.lowercased().contains("per_day") || $0.lowercased().contains("perday") }) {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        }
        if let retry = response.value(forHTTPHeaderField: "Retry-After") {
            if let seconds = Double(retry), seconds.isFinite { return now.addingTimeInterval(max(1, seconds)) }
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
            if let date = formatter.date(from: retry), date > now { return date }
        }
        for detail in details {
            if let delay = detail["retryDelay"] as? String, delay.hasSuffix("s"),
               let seconds = Double(delay.dropLast()), seconds.isFinite { return now.addingTimeInterval(max(1, seconds)) }
        }
        return now.addingTimeInterval(60)
    }
}
