import Foundation
import LunaAppConfig
import LunaCompanionShareCore
import LunaMusicFiles

/// The extension owns resolution; iOS owns the transfer after the sheet closes.
/// Each capture gets a session so the extension and running app never compete
/// for ownership of the same background session.
@MainActor public final class MusicYouTubeShare: NSObject {
    public static let unsupportedMessage = "This item can’t be added to Luna Music."
    public static let sessionPrefix = AppConfig.productBundlePrefix + ".music.youtube-share."
    public static var consume: (() async -> Void)?
    private static var sessions: [String: MusicYouTubeShare] = [:]
    private let capture: CompanionShareCapture?
    private let inbox: CompanionShareInbox
    private var session: URLSession!
    private let identifier: String
    private var completion: (() -> Void)?

    public enum Result {
        case pending
        case downloaded(URL)
        case failed(String, mediaRejected: Bool)
    }
    private struct Outcome: Codable {
        var error: String?
        var mediaRejected = false
    }
    public struct Resolved {
        public let metadata: YouTubeAudioMetadata
        public init(metadata: YouTubeAudioMetadata) { self.metadata = metadata }
    }
    public static func resolve(_ input: String, request: (Data) async throws -> Data) async throws -> Resolved {
        guard let video = YouTubeAudioURL.videoID(input) else { throw unsupported() }
        let ticket = UUID().uuidString
        func rpc(_ value: YouTubeAudioRequest) async throws -> YouTubeAudioResponse {
            var envelope = MusicFileRequest(.youtube); envelope.youtube = value
            let response = try JSONDecoder().decode(MusicFileResponse.self, from: try await request(JSONEncoder().encode(envelope)))
            guard response.error == nil, let result = response.youtube, result.error == nil else { throw unsupported() }
            return result
        }
        do {
            guard try await rpc(.init(.availability)).available == true else { throw unsupported() }
            _ = try await rpc(.init(.resolve, id: ticket, url: YouTubeAudioURL.canonical(video).absoluteString))
            let deadline = Date().addingTimeInterval(120)
            while Date() < deadline {
                try Task.checkCancellation()
                let response = try await rpc(.init(.status, id: ticket))
                if response.state == .resolved, let metadata = response.metadata {
                    guard metadata.videoID == video, metadata.downloadURL.scheme == "https", metadata.downloadURL.host != nil,
                          metadata.headers.allSatisfy({ $0.key.rangeOfCharacter(from: .newlines) == nil && $0.value.rangeOfCharacter(from: .newlines) == nil }) else { throw unsupported() }
                    _ = try? await rpc(.init(.release, id: ticket))
                    return Resolved(metadata: metadata)
                }
                guard response.state == .resolving else { throw unsupported() }
                try await Task.sleep(for: .seconds(1))
            }
            throw unsupported()
        } catch {
            _ = try? await rpc(.init(.release, id: ticket))
            throw unsupported()
        }
    }
    public static func unsupported() -> NSError {
        NSError(domain: "LunaMusicShare", code: 1, userInfo: [NSLocalizedDescriptionKey: unsupportedMessage])
    }
    public static func start(_ resolved: Resolved, title: String, next: Bool, choices: CompanionShareChoices,
                             inbox: CompanionShareInbox) throws {
        let metadata = resolved.metadata
        let budget = max(0, choices.downloadBytesAvailable ?? 2_000_000_000)
        guard budget > 0 else { throw unsupported() }
        let capture = CompanionShareCapture(kind: .podcast,
            text: YouTubeAudioURL.canonical(metadata.videoID).absoluteString,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? metadata.title : title,
            playNext: next, youtube: .init(videoID: metadata.videoID, author: metadata.author,
                                         duration: metadata.duration, maximumBytes: budget))
        // Publish before resume, so even immediate completion can be recovered.
        try inbox.save(capture)
        let transfer = MusicYouTubeShare(capture: capture, inbox: inbox)
        var request = URLRequest(url: metadata.downloadURL)
        request.allHTTPHeaderFields = metadata.headers
        request.allowsCellularAccess = choices.cellularDownloads ?? false
        request.allowsExpensiveNetworkAccess = request.allowsCellularAccess
        transfer.begin(request)
    }
    public static func result(for capture: CompanionShareCapture, inbox: CompanionShareInbox) throws -> Result {
        let directory = inbox.directory(for: capture)
        let outcome = directory.appendingPathComponent("transfer.json")
        guard FileManager.default.fileExists(atPath: outcome.path) else { return .pending }
        let value = try JSONDecoder().decode(Outcome.self, from: Data(contentsOf: outcome))
        if let error = value.error { return .failed(error, mediaRejected: value.mediaRejected) }
        return .downloaded(directory.appendingPathComponent("audio.m4a"))
    }
    /// Called only for the identifier delivered by UIApplication, after the
    /// extension relinquishes its session. Ordinary inbox polling never claims it.
    public static func handleEvents(_ identifier: String, completion: @escaping () -> Void) throws -> Bool {
        guard identifier.hasPrefix(sessionPrefix), let id = UUID(uuidString: String(identifier.dropFirst(sessionPrefix.count))) else { return false }
        let inbox = try CompanionShareInbox.production("music")
        let capture = try inbox.pending().first(where: { $0.id == id && $0.youtube != nil })
        // Polling may have imported and removed the capture before iOS delivers
        // this event. Still reclaim and drain its completed session.
        let transfer = sessions[identifier] ?? MusicYouTubeShare(capture: capture, inbox: inbox, identifier: identifier)
        transfer.completion = completion
        return true
    }
    private convenience init(capture: CompanionShareCapture, inbox: CompanionShareInbox) {
        self.init(capture: capture, inbox: inbox, identifier: Self.sessionPrefix + capture.id.uuidString)
    }
    init(capture: CompanionShareCapture?, inbox: CompanionShareInbox, identifier: String,
         configuration: URLSessionConfiguration? = nil) {
        self.capture = capture; self.inbox = inbox; self.identifier = identifier
        super.init()
        Self.sessions[identifier] = self
        let config = configuration ?? URLSessionConfiguration.background(withIdentifier: identifier)
        if config.identifier != nil { config.sharedContainerIdentifier = AppConfig.provisionedAppGroupID }
        config.sessionSendsLaunchEvents = true; config.isDiscretionary = false
        config.waitsForConnectivity = true; config.timeoutIntervalForResource = 1800
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    func begin(_ request: URLRequest) { session.downloadTask(with: request).resume() }
    nonisolated private static func write(_ outcome: Outcome, directory: URL) throws {
        try JSONEncoder().encode(outcome).write(to: directory.appendingPathComponent("transfer.json"), options: .atomic)
    }
}

extension MusicYouTubeShare: URLSessionDownloadDelegate {
    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let capture else { return }
        let directory = inbox.directory(for: capture)
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  !["html", "json", "xml"].contains(where: { (response.mimeType ?? "").contains($0) }) else { throw YouTubeMediaRejection() }
            let bytes = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes > 0 else { throw YouTubeMediaRejection() }
            guard bytes <= (capture.youtube?.maximumBytes ?? 0) else { throw CocoaError(.fileReadTooLarge) }
            let target = directory.appendingPathComponent("audio.m4a")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
            try Self.write(Outcome(), directory: directory)
        } catch {
            try? Self.write(Outcome(error: error.localizedDescription, mediaRejected: YouTubeAudioFailurePolicy.shouldUseMac(error)), directory: directory)
        }
    }
    nonisolated public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, let capture,
           !FileManager.default.fileExists(atPath: inbox.directory(for: capture).appendingPathComponent("transfer.json").path) {
            try? Self.write(Outcome(error: error.localizedDescription, mediaRejected: YouTubeAudioFailurePolicy.shouldUseMac(error)), directory: inbox.directory(for: capture))
        }
        Task { @MainActor in
            await Self.consume?()
            // Keep delivery of background events alive through durable import.
            if completion == nil { session.finishTasksAndInvalidate() }
        }
    }
    nonisolated public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let capture else { downloadTask.cancel(); return }
        if max(totalBytesWritten, totalBytesExpectedToWrite) > (capture.youtube?.maximumBytes ?? 0) {
            try? Self.write(Outcome(error: "The audio exceeds your download limit."), directory: inbox.directory(for: capture))
            downloadTask.cancel()
        }
    }
    nonisolated public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            await Self.consume?()
            let finish = completion; completion = nil
            finish?(); session.finishTasksAndInvalidate()
        }
    }
    nonisolated public func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        Task { @MainActor in Self.sessions[self.identifier] = nil }
    }
}
