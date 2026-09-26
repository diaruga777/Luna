import Combine
import Foundation
import MediaPlayer

@MainActor
public final class MusicPlaybackController: ObservableObject {
    public static let shared = MusicPlaybackController()
    @Published public private(set) var nowPlaying: MPMediaItem?
    @Published public private(set) var queue: [MPMediaItem] = []
    @Published public private(set) var currentIndex = 0
    @Published public private(set) var isPlaying = false
    @Published public private(set) var playbackTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var sourcePlaylistName: String?
    @Published public private(set) var shuffleEnabled = false
    @Published public private(set) var repeatMode: MPMusicRepeatMode = .none
    @Published public private(set) var errorMessage: String?

    private let player = MPMusicPlayerController.applicationQueuePlayer
    private let defaults = UserDefaults.standard
    private let recencyKey = "LunaMusic.playlistLastPlayed.v1"
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var pendingPlaylistID: UInt64?
    private var requestID = UUID()
    private var queueMutation: Task<Void, Never>?
    private var unshuffledIDs: [UInt64] = []

    private init() {
        player.beginGeneratingPlaybackNotifications()
        player.shuffleMode = .off // Shuffle explicitly, keeping the selected song first.
        player.repeatMode = .none
        for name in [Notification.Name.MPMusicPlayerControllerNowPlayingItemDidChange,
                     .MPMusicPlayerControllerPlaybackStateDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: player, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    public func playSong(_ item: MPMediaItem) async throws {
        if MusicLibraryController.shared.playlists.isEmpty {
            await MusicLibraryController.shared.reload()
        }
        let playlists = MusicLibraryController.shared.playlists
        let recency = defaults.dictionary(forKey: recencyKey) as? [String: Double] ?? [:]
        let candidates = playlists.map {
            MusicQueuePlanner.Playlist(id: $0.persistentID, songIDs: $0.items.map(\.persistentID),
                                       lastPlayed: recency[String($0.persistentID)].map(Date.init(timeIntervalSince1970:)))
        }
        let selected = MusicQueuePlanner.playlist(containing: item.persistentID, in: candidates)
        let playlist = playlists.first { $0.persistentID == selected?.id }
        var generator = SystemRandomNumberGenerator()
        let ids = MusicQueuePlanner.songIDs(startingWith: item.persistentID, playlist: selected, using: &generator)
        var byID: [UInt64: MPMediaItem] = [item.persistentID: item]
        for song in playlist?.items ?? [] { byID[song.persistentID] = song }
        let ordered = ids.compactMap { byID[$0] }
        try await start(ordered, playlist: playlist, shuffled: true,
                        originalIDs: [item.persistentID] + (selected?.songIDs ?? []).filter { $0 != item.persistentID })
    }

    public func play(_ items: [MPMediaItem], playlist: MPMediaPlaylist? = nil, shuffle: Bool = false) async throws {
        let unique = deduplicated(items)
        try await start(shuffle ? unique.shuffled() : unique, playlist: playlist,
                        shuffled: shuffle, originalIDs: unique.map(\.persistentID))
    }

    private func start(_ items: [MPMediaItem], playlist: MPMediaPlaylist?, shuffled: Bool, originalIDs: [UInt64]) async throws {
        guard !items.isEmpty else { throw MusicPlaybackError.emptyQueue }
        let id = UUID()
        requestID = id
        if let queueMutation { await queueMutation.value }
        guard requestID == id else { throw CancellationError() }
        pendingPlaylistID = nil
        errorMessage = nil
        player.shuffleMode = .off
        player.setQueue(with: MPMediaItemCollection(items: items))
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                player.prepareToPlay { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            guard requestID == id else { throw CancellationError() }
            queue = items
            unshuffledIDs = originalIDs
            sourcePlaylistName = playlist?.name
            shuffleEnabled = shuffled
            pendingPlaylistID = playlist?.persistentID
            player.play()
            refresh()
        } catch {
            if requestID == id {
                errorMessage = error.localizedDescription
                pendingPlaylistID = nil
                queue = []
                sourcePlaylistName = nil
                refresh()
            }
            throw error
        }
    }

    public func togglePlayPause() {
        if player.playbackState == .playing { player.pause() }
        else if nowPlaying != nil { player.play() }
        refresh()
    }

    public func next() { player.skipToNextItem(); refresh() }
    public func previous() {
        if player.currentPlaybackTime > 3 { player.skipToBeginning() }
        else { player.skipToPreviousItem() }
        refresh()
    }
    public func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        player.currentPlaybackTime = min(max(0, time), duration)
        refresh()
        changed()
    }
    public func cycleRepeat() {
        switch repeatMode {
        case .none, .default: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .none
        @unknown default: repeatMode = .none
        }
        player.repeatMode = repeatMode
        changed()
    }

    public func setShuffle(_ enabled: Bool) {
        guard shuffleEnabled != enabled else { return }
        shuffleEnabled = enabled
        let order = unshuffledIDs
        mutateUpcoming { items in
            if enabled { items.shuffle() }
            else {
                let indices = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
                items.sort { (indices[$0.persistentID] ?? Int.max) < (indices[$1.persistentID] ?? Int.max) }
            }
        }
    }

    public func playNext(_ item: MPMediaItem) {
        guard nowPlaying != nil else { startFromIdle(item); return }
        mutateUpcoming { items in
            items.removeAll { $0.persistentID == item.persistentID }
            items.insert(item, at: 0)
        }
    }
    public func playLater(_ item: MPMediaItem) {
        guard nowPlaying != nil else { startFromIdle(item); return }
        mutateUpcoming { items in
            items.removeAll { $0.persistentID == item.persistentID }
            items.append(item)
        }
    }
    /// Indices are absolute positions in `queue`; played/current items cannot be edited.
    public func removeUpcoming(at index: Int) {
        guard queue.indices.contains(index), index > currentIndex else { return }
        let id = queue[index].persistentID
        mutateUpcoming { $0.removeAll { $0.persistentID == id } }
    }
    public func moveUpcoming(from source: Int, to destination: Int) {
        guard queue.indices.contains(source), source > currentIndex, destination > currentIndex else { return }
        let id = queue[source].persistentID
        let offset = destination - currentIndex - 1
        mutateUpcoming { items in
            guard let index = items.firstIndex(where: { $0.persistentID == id }) else { return }
            let item = items.remove(at: index)
            items.insert(item, at: min(max(0, offset), items.count))
        }
    }

    private func startFromIdle(_ item: MPMediaItem) {
        Task { do { try await playSong(item) } catch { errorMessage = error.localizedDescription; changed() } }
    }

    private func mutateUpcoming(_ transform: @escaping (inout [MPMediaItem]) -> Void) {
        let prior = queueMutation
        let generation = requestID
        queueMutation = Task { @MainActor [weak self] in
            await prior?.value
            guard let self, self.requestID == generation else { return }
            self.refresh()
            let index = self.currentIndex
            guard self.queue.indices.contains(index), let current = self.nowPlaying else { return }
            let expectedID = current.persistentID
            var upcoming = Array(self.queue.dropFirst(index + 1))
            transform(&upcoming)
            upcoming = self.deduplicated(upcoming).filter { $0.persistentID != expectedID }
            let replacement = upcoming
            let result: (MPMusicPlayerControllerQueue, Error?) = await withCheckedContinuation { continuation in
                self.player.perform(queueTransaction: { mutable in
                    // A track may advance during the transaction: leave that newer queue intact.
                    guard self.player.nowPlayingItem?.persistentID == expectedID,
                          let actualIndex = mutable.items.firstIndex(where: { $0.persistentID == expectedID }) else { return }
                    for item in mutable.items.dropFirst(actualIndex + 1) { mutable.remove(item) }
                    if !replacement.isEmpty {
                        let descriptor = MPMusicPlayerMediaItemQueueDescriptor(itemCollection: MPMediaItemCollection(items: replacement))
                        mutable.insert(descriptor, after: current)
                    }
                }, completionHandler: { queue, error in continuation.resume(returning: (queue, error)) })
            }
            guard self.requestID == generation else { return }
            if let error = result.1 { self.errorMessage = error.localizedDescription }
            else { self.queue = result.0.items }
            self.refresh()
            self.changed()
        }
    }

    private func refresh() {
        let oldID = nowPlaying?.persistentID
        let oldPlaying = isPlaying
        let oldIndex = currentIndex
        nowPlaying = player.nowPlayingItem
        let index = player.indexOfNowPlayingItem
        currentIndex = index == NSNotFound ? 0 : index
        isPlaying = player.playbackState == .playing
        let time = player.currentPlaybackTime
        playbackTime = time.isFinite ? max(0, time) : 0
        duration = nowPlaying?.playbackDuration ?? 0
        if isPlaying, let id = pendingPlaylistID {
            var recency = defaults.dictionary(forKey: recencyKey) as? [String: Double] ?? [:]
            recency[String(id)] = Date().timeIntervalSince1970
            defaults.set(recency, forKey: recencyKey)
            pendingPlaylistID = nil
        }
        if oldID != nowPlaying?.persistentID || oldPlaying != isPlaying || oldIndex != currentIndex { changed() }
    }
    private func changed() { NotificationCenter.default.post(name: .lunaMusicPlaybackChanged, object: self) }
    private func deduplicated(_ items: [MPMediaItem]) -> [MPMediaItem] {
        var seen = Set<UInt64>()
        return items.filter { seen.insert($0.persistentID).inserted }
    }
}

public enum MusicPlaybackError: LocalizedError {
    case emptyQueue
    public var errorDescription: String? { "There are no songs available to play." }
}
