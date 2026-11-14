import AVFoundation
import Combine
import Foundation
import LunaMusicFiles
import LunaPodcastCore
import Network

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
    private let network = NWPathMonitor()
    private var request: ((Data) async throws -> Data)?
    private let library: PodcastLibraryController
    private let startDownload: (PodcastEpisode) async -> Void
    private let directDownload: YouTubeDirectDownload
    private let validate: @Sendable (URL) async throws -> Double
    private var resolved: [String: (String, YouTubeAudioMetadata)] = [:]
    private var adding: [String: Task<PodcastEpisode, Error>] = [:]
    private var capabilityGeneration = UUID()
    private var peerID: (() -> String)?
    private var capabilityPeer: String?
    private let defaults: UserDefaults
    private let capabilityKey = "LunaMusic.youtubeAvailability"
    private struct Capability: Codable { var peer: String; var available: Bool }

    init(library: PodcastLibraryController? = nil, defaults: UserDefaults = .standard, startDownload: ((PodcastEpisode) async -> Void)? = nil,
         directDownload: @escaping @Sendable (URLRequest, Int64, @escaping @Sendable (Double) -> Void) async throws -> URL = { try await YouTubePodcastController.downloadDirect($0, maximumBytes: $1, progress: $2) },
         validate: @escaping @Sendable (URL) async throws -> Double = { try await YouTubePodcastController.validateAudio($0) }) {
        network.start(queue: DispatchQueue(label: "LunaMusic.youtube.network"))
        self.defaults = defaults
        self.startDownload = startDownload ?? { await PodcastDownloads.shared.download($0) }
        self.library = library ?? .shared; self.directDownload = directDownload; self.validate = validate
    }
    deinit { network.cancel() }

    public func configure(peer: (() -> String)? = nil, request: @escaping (Data) async throws -> Data) {
        capabilityGeneration = UUID(); peerID = peer; self.request = request
        capabilityPeer = nil; available = false; restoreAvailability()
    }
    /// Display the last successful capability for this Mac while a fresh read runs.
    public func restoreAvailability() {
        guard let peerID else { return }
        let peer = peerID()
        guard capabilityPeer != peer else { return }
        capabilityGeneration = UUID(); capabilityPeer = peer
        available = false
        if !peer.isEmpty, let data = defaults.data(forKey: capabilityKey),
           let cached = try? JSONDecoder().decode(Capability.self, from: data), cached.peer == peer {
            available = cached.available
        }
    }
    public func refreshAvailability() async {
        restoreAvailability()
        let peer = peerID?()
        guard peer == nil || peer?.isEmpty == false else { return }
        let generation = UUID(); capabilityGeneration = generation
        let result = try? await rpc(.init(.availability))
        restoreAvailability()
        guard let value = result?.available,
              !Task.isCancelled, capabilityGeneration == generation, peerID?() == peer else { return }
        available = value
        if let peer, let data = try? JSONEncoder().encode(Capability(peer: peer, available: value)) {
            defaults.set(data, forKey: capabilityKey)
        }
    }
    public func disconnected() {
        capabilityGeneration = UUID()
        restoreAvailability()
    }

    @discardableResult public func enqueue(_ input: String) async throws -> PodcastEpisode {
        restoreAvailability()
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
                  progress: @escaping @Sendable (Double) -> Void, onMacDownload: () -> Void = {}, directDownload: YouTubeDirectDownload? = nil) async throws -> YouTubeDownloadedAudio {
        guard let video = episode.youtubeVideoID, YouTubeAudioURL.videoID(YouTubeAudioURL.canonical(video).absoluteString) == video else {
            throw PodcastError("This YouTube link is invalid.")
        }
        let ticket: String, metadata: YouTubeAudioMetadata
        if let cached = resolved.removeValue(forKey: video) { (ticket, metadata) = cached }
        else { (ticket, metadata) = try await resolve(video) }
        do {
            let audio = try await download(ticket: ticket, metadata: metadata, maximumBytes: maximumBytes, progress: progress,
                                           onMacDownload: onMacDownload, directDownload: directDownload ?? self.directDownload)
            _ = try? await rpc(.init(.release, id: ticket))
            return audio
        } catch {
            _ = try? await rpc(.init(.release, id: ticket))
            throw error
        }
    }
    private func download(ticket: String, metadata: YouTubeAudioMetadata, maximumBytes: Int64,
                          progress: @escaping @Sendable (Double) -> Void, onMacDownload: () -> Void, directDownload: YouTubeDirectDownload) async throws -> YouTubeDownloadedAudio {
        let request = YouTubeAudioTransfer.request(for: metadata, allowsCellular: library.state.settings.cellularDownloads)
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
        try checkTransferNetwork()
        onMacDownload()
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
                try checkTransferNetwork()
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
            if target == .ready { try checkTransferNetwork() }
            let response = try await rpc(.init(.status, id: ticket))
            if response.state == target { return response }
            guard response.state == .resolving || response.state == .downloading else { throw PodcastError("This audio request expired. Try again.") }
            try await Task.sleep(for: .seconds(1))
        }
        throw URLError(.timedOut)
    }
    private func checkTransferNetwork() throws {
        if !library.state.settings.cellularDownloads, network.currentPath.usesInterfaceType(.cellular) {
            throw PodcastError("Connect to Wi-Fi or allow cellular downloads in Podcast Settings.")
        }
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
        do {
            let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard try await asset.load(.isPlayable) else { throw YouTubeMediaRejection() }
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration)
            guard !tracks.isEmpty, duration.isNumeric, duration > .zero else { throw YouTubeMediaRejection() }

            // An M4A edit can extend beyond the last AAC packet. Map the
            // packet endpoint into the playback timeline to honor real edits,
            // including leading offsets and encoder priming.
            var audioEnd = CMTime.zero
            for track in tracks {
                guard try await track.load(.canProvideSampleCursors) else { return duration.seconds }
                guard let last = track.makeSampleCursorAtLastSampleInDecodeOrder() else { continue }
                let packetEnd = last.presentationTimeStamp + last.currentSampleDuration
                guard packetEnd.isNumeric else { return duration.seconds }
                let segments = try await track.load(.segments)
                for segment in segments where !segment.isEmpty {
                    let mapping = segment.timeMapping
                    let sourceEnd = min(mapping.source.end, packetEnd)
                    guard sourceEnd > mapping.source.start else { continue }
                    let end = CMTimeMapTimeFromRangeToRange(sourceEnd, fromRange: mapping.source, toRange: mapping.target)
                    if end.isNumeric { audioEnd = max(audioEnd, end) }
                }
            }
            guard audioEnd > .zero else { throw YouTubeMediaRejection() }
            return min(duration, audioEnd).seconds
        } catch {
            try Task.checkCancellation()
            if (error as NSError).domain == NSCocoaErrorDomain { throw error }
            throw YouTubeMediaRejection()
        }
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
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("youtube-" + UUID().uuidString).appendingPathExtension("m4a")
        let partial = file.appendingPathExtension("partial")
        defer { try? FileManager.default.removeItem(at: partial) }
        var request = request
        while true {
            let location: URL, response: URLResponse
            do { (location, response) = try await session.download(for: request, delegate: delegate) }
            catch { throw delegate.transferError ?? error }
            defer { try? FileManager.default.removeItem(at: location) }
            switch try YouTubeAudioTransfer.receive(location, response: response, request: request, partial: partial, maximumBytes: maximumBytes) {
            case .complete(let audio):
                try FileManager.default.moveItem(at: audio, to: file)
                return file
            case .next(let next, let fraction):
                progress(fraction)
                request = next
            }
        }
    }
}

private final class YouTubeDirectDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let maximumBytes: Int64
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var error: Error?
    var transferError: Error? { lock.lock(); defer { lock.unlock() }; return error }
    init(maximumBytes: Int64, progress: @escaping @Sendable (Double) -> Void) { self.maximumBytes = maximumBytes; self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        do {
            if let fraction = try YouTubeAudioTransfer.progress(response: downloadTask.response, request: downloadTask.originalRequest,
                written: totalBytesWritten, expected: totalBytesExpectedToWrite, maximumBytes: maximumBytes) {
                progress(fraction)
            }
        } catch {
            lock.lock(); self.error = error; lock.unlock()
            downloadTask.cancel()
        }
    }
}
