import AVFoundation
import UIKit
import Combine
import Foundation
import MediaPlayer
import LunaPodcastCore

@MainActor
public final class MusicPlaybackController: ObservableObject {
    public static let shared = MusicPlaybackController()
    @Published public private(set) var nowPlaying: MusicSong?
    @Published public private(set) var queue: [MusicSong] = []
    @Published public private(set) var currentIndex = 0
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isBuffering = false
    @Published public private(set) var playbackTime: TimeInterval = 0
    @Published public private(set) var duration: TimeInterval = 0
    @Published public private(set) var sourcePlaylistName: String?
    @Published public private(set) var shuffleEnabled = false
    @Published public private(set) var repeatMode: MPMusicRepeatMode = .none
    @Published public private(set) var errorMessage: String?

    public var hasRestorableQueue: Bool { nowPlaying != nil || pendingSnapshot != nil || !queue.isEmpty }
    public var willPlay: (() -> Void)?
    public var remoteSkip: ((MediaSkipGesture.Direction, TimeInterval) -> Void)?

    private let player = MPMusicPlayerController.applicationQueuePlayer
    private let defaults: UserDefaults
    private let vault: VaultMusicController
    private let recencyKey = "LunaMusic.playlistLastPlayed.v1"
    private let snapshotKey = "LunaMusic.playbackQueue.v1"
    private var pendingSnapshot: MusicQueueSnapshot?
    private var needsPreparation = false
    private var isPreparing = false
    private var sourcePlaylistID: MusicID?
    private var lastPersistence = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var pendingPlaylistID: MusicID?
    private var requestID = UUID()
    private var queueMutation: Task<Void, Never>?
    private var unshuffledIDs: [MusicID] = []

    private let filePlayer: AVPlayer
    private lazy var fileSession = MPNowPlayingSession(players: [filePlayer])
    private var loader: VaultMusicResourceLoader?
    private var usesFileQueue = false
    private var fileStatus: NSKeyValueObservation?
    private var didPlayCurrent = false
    private var advancing = false
    private var interruptedPlaying = false
    private var filePlaybackRequested = false
    private var fileStalled = false
    private var remoteTargets: [(MPRemoteCommand, Any)] = []

    init(defaults: UserDefaults = .standard, vault: VaultMusicController = .shared, filePlayer: AVPlayer = AVPlayer()) {
        self.defaults = defaults; self.vault = vault; self.filePlayer = filePlayer
        installFilePlayback()
        player.beginGeneratingPlaybackNotifications()
        if let data = defaults.data(forKey: snapshotKey) {
            pendingSnapshot = try? JSONDecoder().decode(MusicQueueSnapshot.self, from: data)
            needsPreparation = pendingSnapshot != nil && player.nowPlayingItem == nil
            if !needsPreparation { pendingSnapshot = nil }
        }
        observers.append(NotificationCenter.default.addObserver(forName: .lunaMusicLibraryChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.restoreIfNeeded() }
        })
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

    deinit {
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        for (command, target) in remoteTargets { command.removeTarget(target) }
    }

    /// Resolves saved IDs for the paused UI only. The system queue is untouched until Resume.
    public func restoreIfNeeded() async {
        guard needsPreparation, let snapshot = pendingSnapshot else { return }
        let library = MusicLibraryController.shared
        if !library.hasLoaded || library.isLoading { await library.reload(refreshVault: false) }
        guard needsPreparation, pendingSnapshot != nil, !library.isLoading else { return }
        let byID = Dictionary(library.songs.map { ($0.persistentID, $0) }, uniquingKeysWith: { first, _ in first })
        guard let restored = snapshot.resolving(availableIDs: Set(byID.keys)) else {
            pendingSnapshot = nil
            needsPreparation = false
            defaults.removeObject(forKey: snapshotKey)
            return
        }
        queue = restored.songIDs.compactMap { byID[$0] }
        usesFileQueue = queue.contains { $0.source == .vault }
        currentIndex = restored.currentIndex
        nowPlaying = queue[currentIndex]
        duration = nowPlaying?.playbackDuration ?? 0
        playbackTime = min(restored.playbackTime, duration)
        unshuffledIDs = restored.originalSongIDs
        shuffleEnabled = restored.shuffleEnabled
        repeatMode = MPMusicRepeatMode(rawValue: restored.repeatMode) ?? .none
        sourcePlaylistName = restored.sourcePlaylistName
        sourcePlaylistID = restored.sourcePlaylistID
        isPlaying = false
        pendingSnapshot = nil
        changed()
    }

    /// Called by an explicit Play/Resume action, including Shortcuts and playback controls.
    public func resume() async throws {
        await restoreIfNeeded()
        guard hasRestorableQueue else { throw MusicPlaybackError.emptyQueue }
        willPlay?()
        if usesFileQueue {
            if advancing { return }
            filePlaybackRequested = true
            guard !queue.isEmpty else { throw MusicPlaybackError.emptyQueue }
            if needsPreparation || (nowPlaying?.source == .vault && (filePlayer.currentItem == nil || filePlayer.currentItem?.status == .failed)) {
                let time = playbackTime
                try await selectFileQueueItem(at: currentIndex, time: time)
            } else if nowPlaying?.source == .vault {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowAirPlay])
                try AVAudioSession.sharedInstance().setActive(true)
                _ = await fileSession.becomeActiveIfPossible()
                filePlayer.play()
            } else { player.play() }
            return
        }
        guard !isPreparing else { return }
        guard needsPreparation else {
            guard nowPlaying != nil else { throw MusicPlaybackError.emptyQueue }
            player.play()
            refresh()
            return
        }
        guard queue.indices.contains(currentIndex), let current = nowPlaying else { throw MusicPlaybackError.emptyQueue }
        isPreparing = true
        defer { isPreparing = false }
        let generation = UUID()
        requestID = generation
        let descriptor = MPMusicPlayerMediaItemQueueDescriptor(itemCollection: MPMediaItemCollection(items: queue.compactMap(\.mediaItem)))
        descriptor.startItem = current.mediaItem
        if let media = current.mediaItem { descriptor.setStartTime(playbackTime, for: media) }
        player.shuffleMode = .off
        player.repeatMode = repeatMode
        player.setQueue(with: descriptor)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            player.prepareToPlay { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        guard requestID == generation else { throw CancellationError() }
        needsPreparation = false
        pendingPlaylistID = sourcePlaylistID
        errorMessage = nil
        player.play()
        refresh()
        changed()
    }

    public func playSong(_ item: MusicSong, in preferredPlaylist: MusicPlaylist? = nil) async throws {
        if !MusicLibraryController.shared.hasLoaded || MusicLibraryController.shared.isLoading {
            await MusicLibraryController.shared.reload(refreshVault: false)
        }
        let playlists = MusicLibraryController.shared.playlists
        let recency = defaults.dictionary(forKey: recencyKey) as? [String: Double] ?? [:]
        let candidates = playlists.map {
            MusicQueuePlanner.Playlist(id: $0.persistentID, songIDs: $0.items.map(\.persistentID),
                                       lastPlayed: (recency[$0.persistentID.rawValue] ?? recency[$0.persistentID.rawValue.replacingOccurrences(of: "apple:", with: "")]).map(Date.init(timeIntervalSince1970:)),
                                       isAutomatic: !$0.playlistAttributes.intersection([.smart, .genius]).isEmpty)
        }
        let preferred = preferredPlaylist.flatMap { playlist in
            candidates.first { $0.id == playlist.persistentID && $0.songIDs.contains(item.persistentID) }
        }
        let selected = preferred ?? MusicQueuePlanner.playlist(containing: item.persistentID, in: candidates)
        let playlist = preferredPlaylist?.persistentID == selected?.id ? preferredPlaylist : playlists.first { $0.persistentID == selected?.id }
        var generator = SystemRandomNumberGenerator()
        let ids = MusicQueuePlanner.songIDs(startingWith: item.persistentID, playlist: selected, using: &generator)
        var byID: [MusicID: MusicSong] = [item.persistentID: item]
        for song in playlist?.items ?? [] { byID[song.persistentID] = song }
        let ordered = ids.compactMap { byID[$0] }
        try await start(ordered, playlist: playlist, shuffled: selected != nil,
                        originalIDs: [item.persistentID] + (selected?.songIDs ?? []).filter { $0 != item.persistentID })
    }

    public func play(_ items: [MusicSong], playlist: MusicPlaylist? = nil, shuffle: Bool = false) async throws {
        let unique = deduplicated(items)
        try await start(shuffle ? unique.shuffled() : unique, playlist: playlist,
                        shuffled: shuffle, originalIDs: unique.map(\.persistentID))
    }

    private func start(_ items: [MusicSong], playlist: MusicPlaylist?, shuffled: Bool, originalIDs: [MusicID]) async throws {
        guard !items.isEmpty else { throw MusicPlaybackError.emptyQueue }
        willPlay?()
        if items.contains(where: { $0.source == .vault }) {
            let generation = UUID(); requestID = generation
            if let queueMutation { await queueMutation.value }
            guard requestID == generation else { throw CancellationError() }
            player.stop(); filePlayer.pause(); loader?.cancel()
            usesFileQueue = true; pendingSnapshot = nil; needsPreparation = false
            queue = items; unshuffledIDs = originalIDs; currentIndex = 0
            sourcePlaylistName = playlist?.name; sourcePlaylistID = playlist?.persistentID
            shuffleEnabled = shuffled; pendingPlaylistID = playlist?.persistentID
            do { try await selectFileQueueItem(at: 0) }
            catch { report(error); throw error }
            return
        }
        filePlayer.pause(); filePlayer.replaceCurrentItem(with: nil); loader?.cancel(); loader = nil
        usesFileQueue = false; filePlaybackRequested = false; isBuffering = false
        fileSession.nowPlayingInfoCenter.nowPlayingInfo = nil
        let id = UUID()
        requestID = id
        if let queueMutation { await queueMutation.value }
        guard requestID == id else { throw CancellationError() }
        pendingPlaylistID = nil
        pendingSnapshot = nil
        needsPreparation = false
        errorMessage = nil
        player.shuffleMode = .off
        player.repeatMode = repeatMode
        player.setQueue(with: MPMediaItemCollection(items: items.compactMap(\.mediaItem)))
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
            sourcePlaylistID = playlist?.persistentID
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

    public func pause() {
        let preparing = isPreparing || advancing
        requestID = UUID(); isPreparing = false; advancing = false
        filePlaybackRequested = false; isBuffering = false
        filePlayer.pause(); player.pause(); isPlaying = false
        if preparing { needsPreparation = true }
        changed()
    }

    public func togglePlayPause() {
        if !isPlaying { willPlay?() }
        if usesFileQueue {
            if isPlaying || filePlaybackRequested {
                filePlaybackRequested = false; isBuffering = false; filePlayer.pause(); player.pause(); isPlaying = false; changed()
            } else { Task { do { try await resume() } catch { report(error) } } }
            return
        }
        if needsPreparation {
            Task { do { try await resume() } catch { errorMessage = error.localizedDescription; changed() } }
        } else {
            if player.playbackState == .playing { player.pause() }
            else if nowPlaying != nil { player.play() }
            refresh()
        }
    }

    public func next() {
        if usesFileQueue { if needsPreparation { moveRestoredSelection(by: 1) } else { advanceFileQueue(by: 1) }; return }
        if needsPreparation { moveRestoredSelection(by: 1); return }
        player.skipToNextItem(); refresh()
    }
    public func previous() {
        if usesFileQueue { if playbackTime > 3 { seek(to: 0) } else if needsPreparation { moveRestoredSelection(by: -1) } else { advanceFileQueue(by: -1) }; return }
        if needsPreparation {
            if playbackTime > 3 { seek(to: 0) } else { moveRestoredSelection(by: -1) }
            return
        }
        if player.currentPlaybackTime > 3 { player.skipToBeginning() }
        else { player.skipToPreviousItem() }
        refresh()
    }
    public func seek(to time: TimeInterval) {
        guard time.isFinite else { return }
        if usesFileQueue, !needsPreparation {
            let value = min(max(0, time), duration)
            if nowPlaying?.source == .vault { filePlayer.seek(to: CMTime(seconds: value, preferredTimescale: 600)) }
            else { player.currentPlaybackTime = value }
            playbackTime = value; changed(); return
        }
        if needsPreparation { playbackTime = min(max(0, time), duration) }
        else { player.currentPlaybackTime = min(max(0, time), duration); refresh() }
        changed()
    }
    public func cycleRepeat() {
        switch repeatMode {
        case .none, .default: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .none
        @unknown default: repeatMode = .none
        }
        if !needsPreparation && !usesFileQueue { player.repeatMode = repeatMode }
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

    public func playNext(_ item: MusicSong) {
        guard nowPlaying != nil else { startFromIdle(item); return }
        adoptFileQueueIfNeeded(item)
        mutateUpcoming { items in
            items.removeAll { $0.persistentID == item.persistentID }
            items.insert(item, at: 0)
        }
    }
    public func playLater(_ item: MusicSong) {
        guard nowPlaying != nil else { startFromIdle(item); return }
        adoptFileQueueIfNeeded(item)
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

    private func startFromIdle(_ item: MusicSong) {
        Task { do { try await playSong(item) } catch { errorMessage = error.localizedDescription; changed() } }
    }

    private func mutateUpcoming(_ transform: @escaping (inout [MusicSong]) -> Void) {
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
            if self.needsPreparation || self.usesFileQueue {
                self.queue = Array(self.queue.prefix(index + 1)) + upcoming
                self.changed()
                return
            }
            let replacement = upcoming
            let result: (MPMusicPlayerControllerQueue, Error?) = await withCheckedContinuation { continuation in
                self.player.perform(queueTransaction: { mutable in
                    // A track may advance during the transaction: leave that newer queue intact.
                    guard self.player.nowPlayingItem.map { MusicID("apple:\($0.persistentID)") } == expectedID,
                          let actualIndex = mutable.items.firstIndex(where: { MusicID("apple:\($0.persistentID)") == expectedID }) else { return }
                    for item in mutable.items.dropFirst(actualIndex + 1) { mutable.remove(item) }
                    if !replacement.isEmpty {
                        let descriptor = MPMusicPlayerMediaItemQueueDescriptor(itemCollection: MPMediaItemCollection(items: replacement.compactMap(\.mediaItem)))
                        mutable.insert(descriptor, after: current.mediaItem)
                    }
                }, completionHandler: { queue, error in continuation.resume(returning: (queue, error)) })
            }
            guard self.requestID == generation else { return }
            if let error = result.1 { self.errorMessage = error.localizedDescription }
            else { self.queue = result.0.items.map(MusicSong.init) }
            self.refresh()
            self.changed()
        }
    }

    private func refresh() {
        guard !needsPreparation else { return }
        if usesFileQueue { refreshFileQueue(); return }
        let oldID = nowPlaying?.persistentID
        let oldPlaying = isPlaying
        let oldIndex = currentIndex
        nowPlaying = player.nowPlayingItem.map(MusicSong.init)
        let index = player.indexOfNowPlayingItem
        currentIndex = index == NSNotFound ? 0 : index
        isPlaying = player.playbackState == .playing
        let time = player.currentPlaybackTime
        playbackTime = time.isFinite ? max(0, time) : 0
        duration = nowPlaying?.playbackDuration ?? 0
        if isPlaying, let id = pendingPlaylistID {
            var recency = defaults.dictionary(forKey: recencyKey) as? [String: Double] ?? [:]
            recency[id.rawValue] = Date().timeIntervalSince1970
            defaults.set(recency, forKey: recencyKey)
            pendingPlaylistID = nil
        }
        if oldID != nowPlaying?.persistentID || oldPlaying != isPlaying || oldIndex != currentIndex { changed() }
        else if isPlaying && Date().timeIntervalSince(lastPersistence) >= 5 { persistQueue() }
    }

    private func moveRestoredSelection(by offset: Int) {
        guard !queue.isEmpty else { return }
        currentIndex = min(max(0, currentIndex + offset), queue.count - 1)
        nowPlaying = queue[currentIndex]
        duration = nowPlaying?.playbackDuration ?? 0
        playbackTime = 0
        changed()
    }

    private func persistQueue() {
        guard !queue.isEmpty, queue.indices.contains(currentIndex) else { return }
        let snapshot = MusicQueueSnapshot(songIDs: queue.map(\.persistentID), currentIndex: currentIndex,
                                          playbackTime: playbackTime, originalSongIDs: unshuffledIDs,
                                          shuffleEnabled: shuffleEnabled, repeatMode: repeatMode.rawValue,
                                          sourcePlaylistName: sourcePlaylistName, sourcePlaylistID: sourcePlaylistID)
        if let data = try? JSONEncoder().encode(snapshot) { defaults.set(data, forKey: snapshotKey) }
        lastPersistence = Date()
    }

    private func adoptFileQueueIfNeeded(_ song: MusicSong) {
        guard song.source == .vault, !usesFileQueue else { return }
        usesFileQueue = true; didPlayCurrent = isPlaying
        // Retain only the active Apple track in its queue; the shared queue owns continuation.
        if let current = nowPlaying?.mediaItem {
            player.perform(queueTransaction: { mutable in
                for item in mutable.items where item.persistentID != current.persistentID { mutable.remove(item) }
            }, completionHandler: { _, _ in })
        }
    }
    private func installFilePlayback() {
        // Apple's buffering-rate predictor cannot predict a custom resource loader.
        filePlayer.automaticallyWaitsToMinimizeStalling = false
        observers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, self.usesFileQueue, note.object as? AVPlayerItem === self.filePlayer.currentItem else { return }
                self.advanceFileQueue(by: 1, ended: true)
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, self.usesFileQueue, self.nowPlaying?.source == .vault,
                      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
                if raw == AVAudioSession.InterruptionType.began.rawValue {
                    self.interruptedPlaying = self.filePlaybackRequested; self.filePlaybackRequested = false; self.filePlayer.pause()
                } else if self.interruptedPlaying,
                          let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                          AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                    self.filePlaybackRequested = true; self.filePlayer.play()
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, self.usesFileQueue,
                      (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue else { return }
                self.filePlaybackRequested = false; self.filePlayer.pause(); self.refresh()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, note.object as? AVPlayerItem === self.filePlayer.currentItem else { return }
                self.fileStalled = true
            }
        })
        let remote = fileSession.remoteCommandCenter
        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            let target = command.addTarget { [weak self] event in
                guard Thread.isMainThread else {
                    Task { @MainActor in if self?.nowPlaying?.source == .vault { action(event) } }
                    return .success
                }
                return MainActor.assumeIsolated {
                    guard self?.nowPlaying?.source == .vault else { return .commandFailed }
                    action(event); return .success
                }
            }
            remoteTargets.append((command, target))
        }
        add(remote.playCommand) { [weak self] _ in Task { do { try await self?.resume() } catch { self?.report(error) } } }
        add(remote.pauseCommand) { [weak self] _ in self?.filePlaybackRequested = false; self?.filePlayer.pause(); self?.refresh() }
        add(remote.togglePlayPauseCommand) { [weak self] _ in self?.togglePlayPause() }
        add(remote.nextTrackCommand) { [weak self] event in
            if let handler = self?.remoteSkip { handler(.forward, event.timestamp) } else { self?.next() }
        }
        add(remote.previousTrackCommand) { [weak self] event in
            if let handler = self?.remoteSkip { handler(.backward, event.timestamp) } else { self?.previous() }
        }
        add(remote.changePlaybackPositionCommand) { [weak self] event in
            if let event = event as? MPChangePlaybackPositionCommandEvent { self?.seek(to: event.positionTime) }
        }
    }
    private func selectFileQueueItem(at index: Int, time: Double = 0) async throws {
        guard queue.indices.contains(index) else { return }
        let generation = UUID(); requestID = generation
        advancing = true
        defer { if requestID == generation { advancing = false } }
        fileStatus = nil; filePlayer.pause(); filePlayer.replaceCurrentItem(with: nil); loader?.cancel(); loader = nil
        player.stop(); needsPreparation = false; errorMessage = nil; didPlayCurrent = false
        fileStalled = false; filePlaybackRequested = true; isBuffering = true
        currentIndex = index; nowPlaying = queue[index]; playbackTime = time
        duration = queue[index].playbackDuration; isPlaying = false
        let song = queue[index]
        changed()
        if song.source == .vault {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.allowAirPlay])
            try AVAudioSession.sharedInstance().setActive(true)
            let item: AVPlayerItem
            if let url = vault.localURL(song) { item = AVPlayerItem(url: url) }
            else {
                guard let cache = vault.cache else { throw MusicFileError("Connect Luna Mac in Settings to stream this song.") }
                // Prime one MiB before playback. Range reads remain available for
                // tail metadata and seeking; no whole-file download is necessary.
                if let file = song.file, file.size > 0 {
                    _ = try await cache.range(song: song, offset: 0, length: Int(min(Int64(MusicFileProtocol.chunkSize * 2), file.size)))
                }
                guard requestID == generation else { throw CancellationError() }
                let resource = VaultMusicResourceLoader(song: song, cache: cache)
                loader = resource; item = AVPlayerItem(asset: resource.asset)
            }
            item.preferredForwardBufferDuration = 20
            item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            fileStatus = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                Task { @MainActor in
                    guard let self, self.requestID == generation else { return }
                    if item.status == .failed { self.report(item.error ?? MusicFileError("This song couldn’t play. Check your Mac connection and try again.")) }
                }
            }
            filePlayer.replaceCurrentItem(with: item)
            _ = await fileSession.becomeActiveIfPossible()
            guard requestID == generation else { throw CancellationError() }
            if time > 0 { await filePlayer.seek(to: CMTime(seconds: time, preferredTimescale: 600)) }
            guard requestID == generation else { throw CancellationError() }
            if filePlaybackRequested { filePlayer.play() }
        } else if let media = song.mediaItem {
            let descriptor = MPMusicPlayerMediaItemQueueDescriptor(itemCollection: MPMediaItemCollection(items: [media]))
            descriptor.setStartTime(time, for: media)
            player.shuffleMode = .off; player.repeatMode = .none; player.setQueue(with: descriptor)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                player.prepareToPlay { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
            }
            guard requestID == generation else { throw CancellationError() }
            fileSession.nowPlayingInfoCenter.nowPlayingInfo = nil
            if filePlaybackRequested { player.play() }
        }
        refreshFileQueue()
    }
    private func advanceFileQueue(by offset: Int, ended: Bool = false) {
        guard !queue.isEmpty else { return }
        var index = currentIndex + offset
        if ended && repeatMode == .one { index = currentIndex }
        if index >= queue.count {
            if repeatMode == .all { index = 0 }
            else { filePlaybackRequested = false; isBuffering = false; filePlayer.pause(); player.pause(); isPlaying = false; playbackTime = duration; changed(); return }
        }
        index = max(0, index)
        Task { do { try await selectFileQueueItem(at: index) } catch { report(error) } }
    }
    private func refreshFileQueue() {
        guard !advancing else { return }
        let oldPlaying = isPlaying
        let oldBuffering = isBuffering
        if nowPlaying?.source == .vault {
            if fileStalled && filePlaybackRequested, let item = filePlayer.currentItem {
                let time = filePlayer.currentTime().seconds
                let buffered = item.loadedTimeRanges.contains { range in
                    let span = range.timeRangeValue
                    return span.start.seconds <= time + 0.1 && CMTimeRangeGetEnd(span).seconds >= min(duration, time + 3)
                }
                if buffered { fileStalled = false; filePlayer.play() }
            }
            isPlaying = filePlayer.timeControlStatus == .playing
            let time = filePlayer.currentTime().seconds
            playbackTime = time.isFinite ? max(0, time) : 0
            if let length = filePlayer.currentItem?.duration.seconds, length.isFinite { duration = max(0, length) }
        } else {
            isPlaying = player.playbackState == .playing
            let time = player.currentPlaybackTime
            if time.isFinite && time > 0 { playbackTime = time }
            if didPlayCurrent && player.playbackState == .stopped {
                didPlayCurrent = false; advanceFileQueue(by: 1, ended: true); return
            }
        }
        isBuffering = filePlaybackRequested && !isPlaying && errorMessage == nil
        if isPlaying {
            didPlayCurrent = true
            if let id = pendingPlaylistID {
                var recency = defaults.dictionary(forKey: recencyKey) as? [String: Double] ?? [:]
                recency[id.rawValue] = Date().timeIntervalSince1970; defaults.set(recency, forKey: recencyKey)
                vault.recordPlay(playlistID: id); pendingPlaylistID = nil
            }
        }
        if oldPlaying != isPlaying || oldBuffering != isBuffering { changed() }
        else if isPlaying && Date().timeIntervalSince(lastPersistence) >= 5 { changed() }
    }
    private func publishFileNowPlaying() {
        guard let song = nowPlaying, song.source == .vault else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: song.title ?? "Song",
            MPMediaItemPropertyArtist: song.artist ?? "Unknown Artist", MPMediaItemPropertyAlbumTitle: song.albumTitle ?? "",
            MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: playbackTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyPlaybackQueueIndex: currentIndex, MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count]
        if let data = song.file?.artwork, let image = UIImage(data: data) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
        fileSession.nowPlayingInfoCenter.nowPlayingInfo = info
    }
    private func report(_ error: Error) {
        guard !(error is CancellationError) else { return }
        errorMessage = error.localizedDescription; filePlaybackRequested = false; isBuffering = false; isPlaying = false; changed()
    }

    private func changed() {
        persistQueue()
        if usesFileQueue { publishFileNowPlaying() }
        NotificationCenter.default.post(name: .lunaMusicPlaybackChanged, object: self)
    }
    private func deduplicated(_ items: [MusicSong]) -> [MusicSong] {
        var seen = Set<MusicID>()
        return items.filter { seen.insert($0.persistentID).inserted }
    }
}

public enum MusicPlaybackError: LocalizedError {
    case emptyQueue
    public var errorDescription: String? { "There are no songs available to play." }
}
