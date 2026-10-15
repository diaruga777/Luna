import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@MainActor public final class PodcastStore {
    public private(set) var state: PodcastLibraryState
    public let url: URL
    private var revision: UInt64 = 0
    public init(url: URL) throws {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            state = try JSONDecoder().decode(PodcastLibraryState.self, from: Data(contentsOf: url))
            guard state.schemaVersion == 1 else { throw PodcastError("This podcast library requires a newer version of Luna Music.") }
        } else { state = PodcastLibraryState() }
        // Discard the automatic show backlog from older versions, preserving
        // only episodes the listener explicitly queued.
        if !state.continuation.isEmpty { try update { $0.continuation = [] } }
    }
    /// Write before publishing; a failed save cannot silently lose an acknowledged edit.
    public func update(positionOnly: Bool = false, _ edit: (inout PodcastLibraryState) throws -> Void) throws {
        var candidate = state
        try edit(&candidate)
        candidate.updatedAt = Date()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(candidate)
        try data.write(to: url, options: [.atomic])
        state = candidate
        revision &+= 1
        NotificationCenter.default.post(name: .lunaPodcastsChanged, object: self, userInfo: ["positionOnly": positionOnly])
    }
    /// Prepare and encode a snapshot away from the UI thread. If a synchronous
    /// edit or another import wins while suspended, rebuild against its state.
    /// Only the final atomic rename and publication run on the main actor.
    /// The edit must be pure: it may be retried after a concurrent edit.
    @discardableResult public func updateInBackground<Result: Sendable>(
        positionOnly: Bool = false, _ edit: @escaping @Sendable (inout PodcastLibraryState) throws -> Result
    ) async throws -> Result {
        while true {
            try Task.checkCancellation()
            let version = revision, snapshot = state, destination = url
            let prepared = try await Task.detached(priority: .utility) {
                var candidate = snapshot
                let result = try edit(&candidate)
                candidate.updatedAt = Date()
                let directory = destination.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let staging = directory.appendingPathComponent(".podcast-\(UUID().uuidString).tmp")
                do { try JSONEncoder().encode(candidate).write(to: staging) }
                catch { try? FileManager.default.removeItem(at: staging); throw error }
                return (candidate, result, staging)
            }.value
            defer { try? FileManager.default.removeItem(at: prepared.2) }
            try Task.checkCancellation()
            guard revision == version else { continue }
            guard rename(prepared.2.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            state = prepared.0
            revision &+= 1
            NotificationCenter.default.post(name: .lunaPodcastsChanged, object: self, userInfo: ["positionOnly": positionOnly])
            return prepared.1
        }
    }
    public func merge(_ feed: PodcastFeed, existingID: String? = nil) throws -> [String] {
        var newIDs: [String] = []
        try update { newIDs = Self.merge(feed, existingID: existingID, into: &$0) }
        return newIDs
    }
    public func mergeInBackground(_ feed: PodcastFeed, existingID: String? = nil,
                                  follow: Bool? = nil, directoryID: String? = nil,
                                  etag: String? = nil, lastModified: String? = nil) async throws -> [String] {
        try await updateInBackground { state in
            let id = existingID ?? feed.show.id
            let existed = state.shows[id] != nil
            let newIDs = Self.merge(feed, existingID: existingID, into: &state)
            if let follow, !existed || follow { state.shows[id]?.followed = follow }
            if let directoryID { state.shows[id]?.directoryID = directoryID }
            state.shows[id]?.etag = etag; state.shows[id]?.lastModified = lastModified
            return newIDs
        }
    }
    nonisolated private static func merge(_ feed: PodcastFeed, existingID: String?, into state: inout PodcastLibraryState) -> [String] {
        var newIDs: [String] = []
        let id = existingID ?? feed.show.id
        let old = state.shows[id]
        var show = feed.show; show.id = id
        if let old {
            show.followed = old.followed; show.settings = old.settings; show.updatedAt = old.updatedAt
            show.directoryID = old.directoryID ?? show.directoryID
            show.etag = old.etag; show.lastModified = old.lastModified
        } else { show.settings.newestFirst = !show.serial }
        show.lastRefresh = Date(); show.refreshError = nil
        state.shows[id] = show
        for var episode in feed.episodes {
            episode.showID = id; episode.id = PodcastIdentity.episode(showID: id, guid: episode.guid)
            if state.episodes[episode.id] == nil { newIDs.append(episode.id) }
            state.episodes[episode.id] = episode
        }
        // Keep historical episodes when a feed trims its archive: queues,
        // bookmarks and the resume cursor must survive publisher pruning.
        return newIDs
    }
    public func follow(_ id: String, _ value: Bool) throws {
        try update { state in state.shows[id]?.followed = value; state.shows[id]?.updatedAt = Date() }
    }
    public func markListened(_ id: String, _ value: Bool) throws {
        try markListened([id], value)
    }
    public func markListened(_ ids: [String], _ value: Bool) throws {
        try update { state in Self.markListened(ids, value, into: &state) }
    }
    public func markListenedInBackground(_ ids: [String], _ value: Bool) async throws {
        try await updateInBackground { state in Self.markListened(ids, value, into: &state) }
    }
    nonisolated private static func markListened(_ ids: [String], _ value: Bool, into state: inout PodcastLibraryState) {
        for id in ids {
            var progress = state.progress[id] ?? PodcastEpisodeState()
            progress.listened = value; progress.completedAt = value ? Date() : nil
            if !value { progress.position = 0 }
            progress.updatedAt = Date(); state.progress[id] = progress
            if value, let episode = state.episodes[id] { state.cursors[episode.showID] = PodcastCursor(episode: episode) }
        }
        // Manual marking never makes the resume intent choose a new episode.
    }
    public func saveEpisode(_ id: String, _ value: Bool) throws {
        try update { state in
            var progress = state.progress[id] ?? PodcastEpisodeState()
            progress.saved = value; progress.updatedAt = Date(); state.progress[id] = progress
        }
    }
    public func enqueue(_ id: String, next: Bool) throws {
        guard state.episodes[id] != nil, state.currentEpisodeID != id else { return }
        try update { state in
            state.queue.removeAll { $0 == id }; state.continuation.removeAll { $0 == id }
            if next { state.queue.insert(id, at: 0) } else { state.queue.append(id) }
            state.progress[id]?.suppressAutomaticDownload = false
        }
    }
    public func recordPlaybackStarted(_ id: String) throws {
        guard let episode = state.episodes[id] else { return }
        try update { state in
            var progress = state.progress[id] ?? PodcastEpisodeState()
            progress.lastPlayedAt = Date(); progress.updatedAt = Date()
            state.progress[id] = progress
            state.lastPlayedEpisodeID = id; state.currentEpisodeID = id
            state.naturallyExhaustedQueue = false
            state.cursors[episode.showID] = PodcastCursor(episode: episode)
        }
    }
    public func recordPosition(_ id: String, position: Double) throws {
        guard position.isFinite else { return }
        try update(positionOnly: true) { state in
            var progress = state.progress[id] ?? PodcastEpisodeState()
            progress.position = max(0, position); progress.updatedAt = Date(); state.progress[id] = progress
        }
    }
    public func finishNaturally(_ id: String, natural: Bool = true) throws -> String? {
        guard state.currentEpisodeID == id else { return nil }
        var next: String?
        try update { state in
            var progress = state.progress[id] ?? PodcastEpisodeState()
            progress.listened = true; progress.completedAt = Date(); progress.updatedAt = Date()
            state.progress[id] = progress
            state.queue.removeAll { state.episodes[$0] == nil || $0 == id }
            state.continuation = []
            if !state.queue.isEmpty { next = state.queue.removeFirst() }
            state.currentEpisodeID = next
            state.naturallyExhaustedQueue = natural && next == nil
            // Last played remains the completed episode until the next actually plays.
        }
        return next
    }
}
