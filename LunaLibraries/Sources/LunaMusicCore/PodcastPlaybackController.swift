import AVFoundation
import Combine
import MediaPlayer
import UIKit
import LunaPodcastCore

@MainActor public final class PodcastPlaybackController: ObservableObject {
    public static let shared = PodcastPlaybackController()
    public let player = AVPlayer()
    @Published public private(set) var currentEpisode: PodcastEpisode?
    @Published public private(set) var isPlaying = false
    @Published public private(set) var isBuffering = false
    @Published public private(set) var position: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var rate: Float = 1
    @Published public private(set) var chapters: [PodcastChapter] = []
    @Published public private(set) var transcript: [PodcastTranscriptCue] = []
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var sleepDeadline: Date?
    @Published public private(set) var sleepAtEpisodeEnd = false
    public var willPlay: (() -> Void)?
    public var hasRestorableQueue: Bool {
        currentEpisode != nil || library.state.queue.contains { library.state.episodes[$0] != nil }
    }
    private let library: PodcastLibraryController
    private lazy var session = MPNowPlayingSession(players: [player])
    private var observations: [NSKeyValueObservation] = []
    private var observers: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var timeToken: Any?
    private var generation = UUID()
    private var requestedPlayback = false
    private var actualStartRecorded = false
    private var ignoreSeekEnd = false
    private var lastPersistedAt = Date.distantPast
    private var interruptedPlayback = false
    private var artwork: UIImage?
    private var extrasTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var itemObserver: NSKeyValueObservation?
    private var isSelecting = false
    private var needsPreparation = true

    public init(library: PodcastLibraryController = .shared) {
        self.library = library
        if let id = library.state.lastPlayedEpisodeID, let episode = library.state.episodes[id] {
            currentEpisode = episode; position = library.state.progress[id]?.position ?? 0; duration = episode.duration
            rate = library.state.shows[episode.showID]?.settings.playbackRate ?? 1
        }
        player.automaticallyWaitsToMinimizeStalling = true
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.updatePlayback() } })
        timeToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        }
        observers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, note.object as? AVPlayerItem === self.player.currentItem else { return }
                await self.ended()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, note.object as? AVPlayerItem === self.player.currentItem else { return }
                self.fail((note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error) ?? PodcastError("The episode stopped before it finished. Try resuming playback."))
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt else { return }
                if raw == AVAudioSession.InterruptionType.began.rawValue { self.interruptedPlayback = self.requestedPlayback; self.pause() }
                else {
                    defer { self.interruptedPlayback = false }
                    if self.interruptedPlayback, let raw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt,
                       AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume) {
                        do { try await self.resume() } catch { self.fail(error) }
                    }
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            if note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.pause() }
            }
        })
        installRemoteCommands()
    }
    deinit {
        if let timeToken { player.removeTimeObserver(timeToken) }
        observers.forEach(NotificationCenter.default.removeObserver)
        for (command, target) in remoteTargets { command.removeTarget(target) }
        extrasTask?.cancel(); sleepTask?.cancel()
    }
    public func play(_ episode: PodcastEpisode) async throws {
        // A single episode never enrolls the rest of its show in the queue.
        try library.edit { $0.continuation = [] }
        do { try await select(episode) } catch { fail(error); throw error }
    }
    public func playEpisodes(_ episodes: [PodcastEpisode]) async throws {
        guard let first = episodes.first else { return }
        try library.edit { $0.queue = episodes.dropFirst().map(\.id); $0.continuation = [] }
        do { try await select(first) } catch { fail(error); throw error }
    }
    private func select(_ episode: PodcastEpisode, restorePosition: Bool = false) async throws {
        persistPosition()
        willPlay?()
        let token = UUID(); generation = token; isSelecting = true
        defer { if generation == token { isSelecting = false } }
        player.pause(); requestedPlayback = true; actualStartRecorded = false; ignoreSeekEnd = false
        errorMessage = nil; isBuffering = true
        currentEpisode = episode; duration = episode.duration
        let saved = library.state.progress[episode.id]
        position = !restorePosition && saved?.listened == true ? 0 : max(0, saved?.position ?? 0)
        rate = library.state.shows[episode.showID]?.settings.playbackRate ?? 1
        try library.edit { $0.currentEpisodeID = episode.id; $0.queue.removeAll { $0 == episode.id }; $0.continuation.removeAll { $0 == episode.id } }
        let audio = AVAudioSession.sharedInstance()
        // Playback already supports AirPlay. Explicit .allowAirPlay is only
        // valid for .playAndRecord and throws paramErr (-50) here.
        try audio.setCategory(.playback, mode: .spokenAudio)
        try audio.setActive(true)
        let asset: AVURLAsset
        if let local = PodcastDownloads.shared.localURL(episode.id) { asset = AVURLAsset(url: local) }
        else { asset = AVURLAsset(url: episode.mediaURL, options: [AVURLAssetAllowsCellularAccessKey: library.state.settings.cellularStreaming]) }
        let item = AVPlayerItem(asset: asset); item.audioTimePitchAlgorithm = .timeDomain
        item.preferredForwardBufferDuration = 30
        itemObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if item.status == .failed { self.fail(item.error ?? PodcastError("This episode could not be played.")) }
            }
        }
        player.replaceCurrentItem(with: item)
        _ = await session.becomeActiveIfPossible()
        guard token == generation else { throw CancellationError() }
        if position > 0 { await player.seek(to: CMTime(seconds: position, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
        guard token == generation else { throw CancellationError() }
        needsPreparation = false
        if requestedPlayback { player.playImmediately(atRate: rate) }
        loadExtras(episode, token: token)
        publish()
    }
    public func resume() async throws {
        guard let episode = currentEpisode ?? library.state.queue.compactMap({ library.state.episodes[$0] }).first else { return }
        willPlay?()
        guard player.currentItem != nil, player.currentItem?.status != .failed, !isSelecting, !needsPreparation else { try await select(episode, restorePosition: true); return }
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        _ = await session.becomeActiveIfPossible()
        requestedPlayback = true; errorMessage = nil; player.playImmediately(atRate: rate); publish()
    }
    /// No recommendation or unrelated "Now Playing" hand-off is involved.
    public func resumeLastPodcast() async throws {
        let store = try library.requireStore()
        if store.state.naturallyExhaustedQueue { await library.refresh(force: true) }
        switch PodcastPolicies.resumeDecision(store.state) {
        case .nothing: return
        case .resume(let id):
            guard let episode = store.state.episodes[id] else { return }
            if currentEpisode?.id == id, player.currentItem != nil { try await resume() }
            else { try await select(episode, restorePosition: true) }
        case .start(let id):
            guard let episode = store.state.episodes[id] else { return }
            // Only one eligible episode is selected, preserving the intent's
            // deterministic contract rather than populating a recommendation queue.
            try await play(episode)
        }
    }
    public func pause() {
        requestedPlayback = false; player.pause(); isPlaying = false; isBuffering = false
        if isSelecting { generation = UUID(); isSelecting = false; needsPreparation = true }
        persistPosition(); publish()
    }
    public func toggle() { if requestedPlayback { pause() } else { Task { do { try await resume() } catch { fail(error) } } } }
    public func seek(to seconds: Double) {
        guard seconds.isFinite, currentEpisode != nil else { return }
        let target = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        ignoreSeekEnd = duration > 0 && target >= duration - 0.25
        position = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        persistPosition(); publish()
    }
    public func skip(backward: Bool) { seek(to: position + (backward ? -library.state.settings.skipBack : library.state.settings.skipForward)) }
    public func setRate(_ value: Float) {
        guard value.isFinite, (0.5...3).contains(value) else { return }
        rate = value
        if requestedPlayback { player.rate = value }
        if let id = currentEpisode?.showID { do { try library.edit { $0.shows[id]?.settings.playbackRate = value; $0.shows[id]?.updatedAt = Date() } } catch { fail(error) } }
        publish()
    }
    public func setSleepTimer(minutes: Int?, endOfEpisode: Bool = false) {
        sleepTask?.cancel(); sleepAtEpisodeEnd = endOfEpisode
        sleepDeadline = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        if let minutes {
            sleepTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(Double(minutes) * 60)); guard !Task.isCancelled else { return }; self?.pause(); self?.sleepDeadline = nil }
                catch {}
            }
        }
    }
    private func tick(_ time: Double) {
        guard !isSelecting, player.currentItem != nil else { return }
        if time.isFinite { position = max(0, time) }
        if let length = player.currentItem?.duration.seconds, length.isFinite { duration = max(0, length) }
        if requestedPlayback, Date().timeIntervalSince(lastPersistedAt) >= 5 { persistPosition(); publish() }
    }
    private func updatePlayback() {
        isPlaying = player.timeControlStatus == .playing
        isBuffering = requestedPlayback && player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        if isPlaying, !actualStartRecorded, let episode = currentEpisode {
            do { try library.requireStore().recordPlaybackStarted(episode.id); actualStartRecorded = true; library.reloadState() }
            catch { fail(error); return }
        }
        publish()
    }
    private func ended() async {
        guard actualStartRecorded, !ignoreSeekEnd, let episode = currentEpisode else { pause(); return }
        persistPosition(); requestedPlayback = false; isPlaying = false; isBuffering = false
        do {
            if sleepAtEpisodeEnd {
                try library.requireStore().markListened(episode.id, true)
                try library.edit { $0.naturallyExhaustedQueue = $0.queue.isEmpty }
                sleepAtEpisodeEnd = false; publish(); return
            }
            let next = try library.requireStore().finishNaturally(episode.id); library.reloadState()
            if let next, let episode = library.state.episodes[next] { try await select(episode) }
            else { publish(); await PodcastDownloads.shared.reconcile() }
        } catch { fail(error) }
    }
    public func persistPosition() {
        guard let id = currentEpisode?.id, actualStartRecorded else { return }
        do { try library.requireStore().recordPosition(id, position: position); library.reloadState(); lastPersistedAt = Date() }
        catch { errorMessage = error.localizedDescription }
    }
    public func fail(_ error: Error) {
        guard !(error is CancellationError) else { return }
        requestedPlayback = false; player.pause(); isPlaying = false; isBuffering = false
        errorMessage = error.localizedDescription; publish()
    }
    private func publish() {
        guard let episode = currentEpisode else { return }
        let show = library.state.shows[episode.showID]
        var info: [String: Any] = [MPMediaItemPropertyTitle: episode.title, MPMediaItemPropertyArtist: show?.title ?? "Podcast",
            MPMediaItemPropertyAlbumTitle: show?.title ?? "Podcast", MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? rate : 0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate, MPNowPlayingInfoPropertyExternalContentIdentifier: episode.id,
            MPNowPlayingInfoPropertyMediaType: (episode.isVideo ? MPNowPlayingInfoMediaType.video : .audio).rawValue]
        if let artwork { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork } }
        session.nowPlayingInfoCenter.nowPlayingInfo = info
        session.remoteCommandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: library.state.settings.skipBack)]
        session.remoteCommandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: library.state.settings.skipForward)]
        NotificationCenter.default.post(name: .lunaPodcastPlaybackChanged, object: self)
    }
    private func installRemoteCommands() {
        let remote = session.remoteCommandCenter
        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            command.isEnabled = true
            remoteTargets.append((command, command.addTarget { event in
                Task { @MainActor in action(event) }; return .success
            }))
        }
        add(remote.playCommand) { [weak self] _ in Task { do { try await self?.resume() } catch { self?.fail(error) } } }
        add(remote.pauseCommand) { [weak self] _ in self?.pause() }
        add(remote.togglePlayPauseCommand) { [weak self] _ in self?.toggle() }
        add(remote.stopCommand) { [weak self] _ in self?.pause() }
        for command in [remote.skipBackwardCommand, remote.previousTrackCommand] {
            add(command) { event in MediaPlaybackCoordinator.shared.skip(.backward, timestamp: event.timestamp) }
        }
        for command in [remote.skipForwardCommand, remote.nextTrackCommand] {
            add(command) { event in MediaPlaybackCoordinator.shared.skip(.forward, timestamp: event.timestamp) }
        }
        add(remote.changePlaybackPositionCommand) { [weak self] event in if let event = event as? MPChangePlaybackPositionCommandEvent { self?.seek(to: event.positionTime) } }
        remote.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]
        add(remote.changePlaybackRateCommand) { [weak self] event in if let event = event as? MPChangePlaybackRateCommandEvent { self?.setRate(event.playbackRate) } }
    }
    private func loadExtras(_ episode: PodcastEpisode, token: UUID) {
        extrasTask?.cancel(); chapters = episode.chapters; transcript = []; artwork = nil
        extrasTask = Task { [weak self] in
            guard let self else { return }
            if let url = episode.artworkURL ?? library.state.shows[episode.showID]?.artworkURL,
               let (data, _) = try? await URLSession.shared.data(from: url), data.count < 15_000_000, generation == token {
                artwork = UIImage(data: data); publish()
            }
            if let url = episode.chaptersURL {
                struct Document: Decodable { struct Chapter: Decodable { var startTime: Double; var title: String?; var url: String?; var img: String? }; var chapters: [Chapter] }
                if let (data, _) = try? await URLSession.shared.data(from: url), data.count < 5_000_000,
                   let document = try? JSONDecoder().decode(Document.self, from: data), generation == token {
                    chapters = document.chapters.filter { $0.startTime.isFinite && $0.startTime >= 0 }.map { .init(start: $0.startTime, title: $0.title ?? "Chapter", url: PodcastIdentity.webURL($0.url), imageURL: PodcastIdentity.webURL($0.img)) }.sorted { $0.start < $1.start }
                }
            }
            if chapters.isEmpty, let asset = player.currentItem?.asset,
               let locales = try? await asset.load(.availableChapterLocales), let locale = locales.first,
               let groups = try? await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [.commonKeyTitle]), generation == token {
                var result: [PodcastChapter] = []
                for group in groups {
                    let title = try? await group.items.first?.load(.stringValue)
                    result.append(.init(start: group.timeRange.start.seconds, title: title ?? "Chapter"))
                }
                if generation == token { chapters = result }
            }
            if let reference = episode.transcripts.first {
                let cache = PodcastLibraryController.directory.appendingPathComponent("transcript-\(PodcastIdentity.hash(reference.url.absoluteString)).json")
                if let data = try? Data(contentsOf: cache), let cues = try? JSONDecoder().decode([PodcastTranscriptCue].self, from: data), generation == token { transcript = cues }
                else if let (data, response) = try? await URLSession.shared.data(from: reference.url),
                        let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                        let cues = try? PodcastTranscript.parse(data, type: reference.type), generation == token {
                    transcript = cues; try? JSONEncoder().encode(cues).write(to: cache, options: [.atomic])
                }
            }
        }
    }
}
