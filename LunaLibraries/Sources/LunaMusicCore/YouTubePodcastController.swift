import AVFoundation
import Combine
import Foundation
import LunaMusicFiles
import LunaPodcastCore

typealias YouTubeDirectDownload = @Sendable (URLRequest, Int64, @escaping @Sendable (Double) -> Void) async throws -> URL

struct YouTubeDownloadedAudio: Sendable {
    var url: URL
    var duration: Double
}

/// Resolves on the paired Mac, tries the media request on this device, and only
/// asks the Mac to download after a server/format rejection. Signed URLs and
/// headers stay out of the library/manifest; URLSession owns any pending
/// background request. Persisted episodes keep the video ID.
@MainActor public final class YouTubePodcastController: ObservableObject {
    public static let shared = YouTubePodcastController()
    public static let showID = "youtube-audio"
    @Published public private(set) var available = false
    private var request: ((Data) async throws -> Data)?
    private let library: PodcastLibraryController
    private let startDownload: (PodcastEpisode) async -> Void
    private let directDownload: YouTubeDirectDownload
    private let validate: @Sendable (URL) async throws -> Double
    private var resolved: [String: (String, YouTubeAudioMetadata)] = [:]
    private var adding: [String: Task<PodcastEpisode, Error>] = [:]
    private var capabilityGeneration = UUID()

    init(library: PodcastLibraryController? = nil, startDownload: ((PodcastEpisode) async -> Void)? = nil,
         directDownload: @escaping @Sendable (URLRequest, Int64, @escaping @Sendable (Double) -> Void) async throws -> URL = { try await YouTubePodcastController.downloadDirect($0, maximumBytes: $1, progress: $2) },
         validate: @escaping @Sendable (URL) async throws -> Double = { try await YouTubePodcastController.validateAudio($0) }) {
        self.startDownload = startDownload ?? { await PodcastDownloads.shared.download($0) }
        self.library = library ?? .shared; self.directDownload = directDownload; self.validate = validate
    }
    public func configure(request: @escaping (Data) async throws -> Data) { self.request = request }
    public func refreshAvailability() async {
        let generation = UUID(); capabilityGeneration = generation
        let result = try? await rpc(.init(.availability))
        guard capabilityGeneration == generation else { return }
        available = result?.available == true
    }
    public func disconnected() { capabilityGeneration = UUID(); available = false }

    @discardableResult public func enqueue(_ input: String) async throws -> PodcastEpisode {
        guard available else { throw PodcastError("Connect to Luna Mac and try again.") }
        guard let video = YouTubeAudioURL.videoID(input) else { throw PodcastError("Enter a YouTube video link.") }
        if let task = adding[video] { return try await task.value }
        let task = Task { () throws -> PodcastEpisode in
            let id = PodcastIdentity.episode(showID: Self.showID, guid: video)
            if let existing = library.state.episodes[id] {
                try library.requireStore().enqueue(id, next: false); library.reloadState()
                await startDownload(existing)
                return existing
            }
            let (ticket, metadata) = try await resolve(video)
            resolved[video] = (ticket, metadata)
            let episode: PodcastEpisode
            do {
                episode = try enqueueResolved(video: video, title: metadata.title, author: metadata.author,
                                              duration: metadata.duration, next: false)
            } catch {
                resolved[video] = nil; _ = try? await rpc(.init(.release, id: ticket)); throw error
            }
            await startDownload(episode)
            return episode
        }
        adding[video] = task
        defer { adding[video] = nil }
        return try await task.value
    }
    /// Shared transfers supply stable metadata without persisting their stream request.
    func enqueueResolved(video: String, title: String, author: String, duration: Double, next: Bool) throws -> PodcastEpisode {
        guard YouTubeAudioURL.videoID(YouTubeAudioURL.canonical(video).absoluteString) == video else { throw PodcastError("This YouTube link is invalid.") }
        let id = PodcastIdentity.episode(showID: Self.showID, guid: video)
        let episode: PodcastEpisode
        if let existing = library.state.episodes[id] { episode = existing }
        else {
            var show = PodcastShow(feedURL: URL(string: "lunamusic://youtube")!, title: "YouTube", author: author, id: Self.showID)
            show.followed = true; show.settings.automaticDownloadLimit = 0; show.settings.notifications = false
            var value = PodcastEpisode(showID: Self.showID, guid: video, title: title, publishedAt: Date(), mediaURL: YouTubeAudioURL.canonical(video))
            value.youtubeVideoID = video; value.duration = duration; value.mediaType = "audio/mp4"; value.websiteURL = value.mediaURL
            try library.edit { state in
                state.shows[show.id] = state.shows[show.id] ?? show
                state.episodes[value.id] = value
            }
            episode = value
        }
        try library.requireStore().enqueue(episode.id, next: next); library.reloadState()
        return episode
    }
    func download(_ episode: PodcastEpisode, maximumBytes: Int64,
                  progress: @escaping @Sendable (Double) -> Void, directDownload: YouTubeDirectDownload? = nil) async throws -> YouTubeDownloadedAudio {
        guard let video = episode.youtubeVideoID, YouTubeAudioURL.videoID(YouTubeAudioURL.canonical(video).absoluteString) == video else {
            throw PodcastError("This YouTube link is invalid.")
        }
        let ticket: String, metadata: YouTubeAudioMetadata
        if let cached = resolved.removeValue(forKey: video) { (ticket, metadata) = cached }
        else { (ticket, metadata) = try await resolve(video) }
        do {
            let audio = try await download(ticket: ticket, metadata: metadata, maximumBytes: maximumBytes, progress: progress, directDownload: directDownload ?? self.directDownload)
            _ = try? await rpc(.init(.release, id: ticket))
            return audio
        } catch {
            _ = try? await rpc(.init(.release, id: ticket))
            throw error
        }
    }
    private func download(ticket: String, metadata: YouTubeAudioMetadata, maximumBytes: Int64,
                          progress: @escaping @Sendable (Double) -> Void, directDownload: YouTubeDirectDownload) async throws -> YouTubeDownloadedAudio {
        var request = URLRequest(url: metadata.downloadURL)
        request.allHTTPHeaderFields = metadata.headers
        request.allowsCellularAccess = library.state.settings.cellularDownloads
        request.allowsExpensiveNetworkAccess = request.allowsCellularAccess
        do {
            let url = try await directDownload(request, maximumBytes, progress)
            do {
                let duration = try await validate(url)
                try Task.checkCancellation()
                return .init(url: url, duration: duration)
            } catch {
                try? FileManager.default.removeItem(at: url)
                try Task.checkCancellation()
                // Validation only reads the downloaded asset. A missing file or
                // denied filesystem access is a local problem, not a Mac retry.
                if (error as NSError).domain == NSCocoaErrorDomain { throw error }
                throw YouTubeMediaRejection()
            }
        } catch {
            try Task.checkCancellation()
            guard YouTubeAudioFailurePolicy.shouldUseMac(error) else { throw error }
        }
        progress(0)
        _ = try await rpc(.init(.download, id: ticket, maximumBytes: maximumBytes))
        let response = try await poll(ticket, until: .ready)
        guard let size = response.size, size > 0, size <= maximumBytes else { throw PodcastError("The audio exceeds your download limit.") }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("youtube-" + UUID().uuidString).appendingPathExtension("m4a")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw PodcastError("The audio file couldn’t be saved.") }
        do {
            let output = try FileHandle(forWritingTo: file); defer { try? output.close() }
            var offset: Int64 = 0
            while offset < size {
                try Task.checkCancellation()
                let length = Int(min(Int64(MusicFileProtocol.chunkSize), size - offset))
                let part = try await rpc(.init(.read, id: ticket, offset: offset, length: length))
                guard part.state == .ready, part.size == size, let bytes = part.data, bytes.count == length else { throw PodcastError("The audio transfer was incomplete. Try again.") }
                try output.write(contentsOf: bytes); offset += Int64(bytes.count)
                progress(Double(offset) / Double(size))
            }
            try output.synchronize()
            let duration = try await validate(file)
            try Task.checkCancellation()
            return .init(url: file, duration: duration)
        } catch { try? FileManager.default.removeItem(at: file); throw error }
    }
    private func resolve(_ video: String) async throws -> (String, YouTubeAudioMetadata) {
        let ticket = UUID().uuidString
        do {
            _ = try await rpc(.init(.resolve, id: ticket, url: YouTubeAudioURL.canonical(video).absoluteString))
            let result = try await poll(ticket, until: .resolved)
            guard let metadata = result.metadata, metadata.videoID == video,
                  metadata.downloadURL.scheme == "https", metadata.downloadURL.host != nil,
                  metadata.headers.allSatisfy({ $0.key.rangeOfCharacter(from: .newlines) == nil && $0.value.rangeOfCharacter(from: .newlines) == nil }) else {
                throw PodcastError("The Mac didn’t return a valid audio stream.")
            }
            return (ticket, metadata)
        } catch {
            _ = try? await rpc(.init(.release, id: ticket)); throw error
        }
    }
    private func poll(_ ticket: String, until target: YouTubeAudioResponse.State) async throws -> YouTubeAudioResponse {
        let deadline = Date().addingTimeInterval(2400)
        while Date() < deadline {
            try Task.checkCancellation()
            let response = try await rpc(.init(.status, id: ticket))
            if response.state == target { return response }
            guard response.state == .resolving || response.state == .downloading else { throw PodcastError("This audio request expired. Try again.") }
            try await Task.sleep(for: .seconds(1))
        }
        throw URLError(.timedOut)
    }
    private func rpc(_ request: YouTubeAudioRequest) async throws -> YouTubeAudioResponse {
        guard let send = self.request else { throw PodcastError("Connect to Luna Mac and try again.") }
        var envelope = MusicFileRequest(.youtube); envelope.youtube = request
        let bytes = try await send(JSONEncoder().encode(envelope))
        let envelopeResponse = try JSONDecoder().decode(MusicFileResponse.self, from: bytes)
        if let message = envelopeResponse.error { throw PodcastError(message) }
        guard let response = envelopeResponse.youtube else { throw PodcastError("Update Luna Mac and try again.") }
        if let message = response.error { throw PodcastError(message) }
        return response
    }
    nonisolated static func validateAudio(_ url: URL) async throws -> Double {
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable), !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw YouTubeMediaRejection() }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw YouTubeMediaRejection() }
        return duration
    }
    nonisolated private static func downloadDirect(_ request: URLRequest, maximumBytes: Int64,
        progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let config = URLSessionConfiguration.ephemeral
        config.allowsCellularAccess = request.allowsCellularAccess
        config.allowsExpensiveNetworkAccess = request.allowsExpensiveNetworkAccess
        config.waitsForConnectivity = false; config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 1800
        let delegate = YouTubeDirectDownloadDelegate(maximumBytes: maximumBytes, progress: progress)
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let location: URL, response: URLResponse
        do { (location, response) = try await session.download(for: request, delegate: delegate) }
        catch {
            if delegate.exceededLimit { throw PodcastError("The audio exceeds your download limit.") }
            throw error
        }
        defer { try? FileManager.default.removeItem(at: location) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !["html", "json", "xml"].contains(where: { (http.mimeType ?? "").contains($0) }) else { throw YouTubeMediaRejection() }
        let size = (try FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size <= maximumBytes else { throw PodcastError("The audio exceeds your download limit.") }
        guard size > 0 else { throw YouTubeMediaRejection() }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("youtube-" + UUID().uuidString).appendingPathExtension("m4a")
        try FileManager.default.moveItem(at: location, to: file)
        return file
    }
}

private final class YouTubeDirectDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maximumBytes: Int64
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var exceeded = false
    var exceededLimit: Bool { lock.lock(); defer { lock.unlock() }; return exceeded }
    init(maximumBytes: Int64, progress: @escaping @Sendable (Double) -> Void) { self.maximumBytes = maximumBytes; self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if max(totalBytesWritten, totalBytesExpectedToWrite) > maximumBytes {
            lock.lock(); exceeded = true; lock.unlock(); downloadTask.cancel()
        } else { progress(totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0) }
    }
}
