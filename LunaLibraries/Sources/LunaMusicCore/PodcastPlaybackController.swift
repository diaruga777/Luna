import AVFoundation
import Combine
import MediaPlayer
import UIKit
import OSLog
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
    @Published public private(set) var isLoadingTranscript = false
    @Published public private(set) var isLoadingChapters = false
    @Published public private(set) var transcriptError: String?
    @Published public private(set) var chaptersError: String?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var sleepDeadline: Date?
    @Published public private(set) var sleepAtEpisodeEnd = false
    public var willPlay: (() -> Void)?
    public var remoteSkip: ((MediaSkipGesture.Direction, TimeInterval) -> Void)?
    public var hasRestorableQueue: Bool {
        currentEpisode != nil || library.state.queue.contains { library.state.episodes[$0] != nil }
    }
    private let library: PodcastLibraryController
    private let downloads: PodcastDownloads
    lazy var session: MPNowPlayingSession = {
        let session = MPNowPlayingSession(players: [player])
        // Let AVFoundation publish transport state directly, including the
        // playing -> paused transition after a background intent finishes.
        session.automaticallyPublishesNowPlayingInfo = true
        return session
    }()
    private let log = Logger(subsystem: "LunaMusic", category: "PodcastPlayback")
    private var observations: [NSKeyValueObservation] = []
    private var observers: [NSObjectProtocol] = []
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var timeToken: Any?
    private var generation = UUID()
    private var playbackRevision = UUID()
    private var requestedPlayback = false
    private var actualStartRecorded = false
    private var pendingSeek: Double?
    private var seekCompletion: ((Bool) -> Void)?
    private func finishSeek(_ finished: Bool) {
        let completion = seekCompletion; seekCompletion = nil; completion?(finished)
    }
    private var seekGeneration = UUID()
    private var isCompleting = false
    private var lastPersistedAt = Date.distantPast
    private var positionSaveTask: Task<Void, Never>?
    private var interruptedPlayback = false
    private var artwork: UIImage?
    private var extrasTask: Task<Void, Never>?
    private var extrasTimeoutTask: Task<Void, Never>?
    private var bufferingTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var itemObserver: NSKeyValueObservation?
    private var isSelecting = false
    private var needsPreparation = true
    private lazy var sessionActivation = MediaSessionActivation(session: session) { [weak self] in
        self?.requestedPlayback == true
    }
    private var playbackStartTime: Double?
    private var playbackResumePosition: Double = 0
    private var primingPlaybackRevision: UUID?
    // isActive identifies the app's session, not the system's playback app.
    // Retain ownership only after audible playback, until another source takes it.
    private var retainsPlaybackSession = false
    private var startupTimeToken: Any?
    private var remotePlaybackTask: Task<Void, Never>?
    private var remotePlaybackRevision = UUID()

    public init(library: PodcastLibraryController = .shared, downloads: PodcastDownloads = .shared) {
        self.library = library; self.downloads = downloads
        if let id = library.state.currentEpisodeID ?? library.state.lastPlayedEpisodeID, let episode = library.state.episodes[id] {
            currentEpisode = episode; position = library.state.progress[id]?.position ?? 0; duration = downloads.cachedDuration(episode.id) ?? episode.duration
            rate = library.state.shows[episode.showID]?.settings.playbackRate ?? 1
        }
        // Recover a completed saved item without taking audio ownership on launch.
        if let episode = currentEpisode, isAtEnd || library.state.progress[episode.id]?.listened == true,
           let next = library.state.queue.compactMap({ library.state.episodes[$0] }).first {
            do {
                try library.edit {
                    var progress = $0.progress[episode.id] ?? PodcastEpisodeState()
                    progress.listened = true; progress.completedAt = progress.completedAt ?? Date()
                    $0.progress[episode.id] = progress
                    $0.currentEpisodeID = next.id; $0.queue.removeAll { $0 == next.id }
                }
                currentEpisode = next; position = library.state.progress[next.id]?.listened == true ? 0 : library.state.progress[next.id]?.position ?? 0
                duration = downloads.cachedDuration(next.id) ?? next.duration; rate = library.state.shows[next.showID]?.settings.playbackRate ?? 1
            } catch { errorMessage = error.localizedDescription }
        }
        player.actionAtItemEnd = .pause
        player.automaticallyWaitsToMinimizeStalling = true
        observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in Task { @MainActor in self?.updatePlayback() } })
        timeToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        observers.append(NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, note.object as? AVPlayerItem === self.player.currentItem else { return }
                guard self.requestedPlayback, self.pendingSeek == nil, !self.isSelecting else { return }
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
                if raw == AVAudioSession.InterruptionType.began.rawValue {
                    self.relinquishPlaybackSession()
                    self.interruptedPlayback = self.requestedPlayback; self.pause()
                }
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
        if let startupTimeToken { player.removeTimeObserver(startupTimeToken) }
        observers.forEach(NotificationCenter.default.removeObserver)
        for (command, target) in remoteTargets { command.removeTarget(target) }
        extrasTask?.cancel(); extrasTimeoutTask?.cancel(); sleepTask?.cancel(); bufferingTask?.cancel()
    }
    private func installItem(_ episode: PodcastEpisode, url: URL, token: UUID) -> AVURLAsset {
        let asset = AVURLAsset(url: url, options: [
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
            AVURLAssetAllowsCellularAccessKey: library.state.settings.cellularStreaming
        ])
        // Duration/chapters are not prerequisites for decoding the first audio.
        let item = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: [.tracks])
        item.audioTimePitchAlgorithm = .timeDomain
        item.preferredForwardBufferDuration = url.isFileURL ? 0 : 3
        player.automaticallyWaitsToMinimizeStalling = !url.isFileURL
        itemObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.generation == token else { return }
                if item.status == .failed { self.fail(item.error ?? PodcastError("This episode could not be played.")) }
            }
        }
        player.replaceCurrentItem(with: item)
        return asset
    }
    private func clearPlaybackStart() {
        playbackStartTime = nil
        if let startupTimeToken { player.removeTimeObserver(startupTimeToken) }
        startupTimeToken = nil
    }
    private func startPlayback() {
        clearPlaybackStart()
        let time = player.currentTime().seconds
        playbackStartTime = time.isFinite ? time : position
        playbackResumePosition = playbackStartTime ?? position
        // Observe startup closely, then remove this observer once the clock
        // advances. Normal playback keeps its existing half-second cadence.
        startupTimeToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updatePlayback() }
        }
        player.playImmediately(atRate: rate)
    }
    private func activateSession() { sessionActivation.request() }
    func receiveRemoteSkip(_ direction: MediaSkipGesture.Direction) {
        // The recognizer and its expiration must use the same monotonic clock.
        // MPRemoteCommandEvent does not document its timestamp's clock origin.
        if let remoteSkip { remoteSkip(direction, ProcessInfo.processInfo.systemUptime) }
        else { skip(backward: direction == .backward) }
    }
    public func play(_ episode: PodcastEpisode) async throws {
        playbackRevision = UUID()
        // A single episode never enrolls the rest of its show in the queue.
        if !library.state.continuation.isEmpty { try library.edit { $0.continuation = [] } }
        do { try await select(episode, queueInterruptedEpisode: true) } catch { fail(error); throw error }
    }
    public func playEpisodes(_ episodes: [PodcastEpisode]) async throws {
        guard let first = episodes.first else { return }
        playbackRevision = UUID()
        try library.edit { $0.queue = episodes.dropFirst().map(\.id); $0.continuation = [] }
        do { try await select(first) } catch { fail(error); throw error }
    }
    private func select(_ episode: PodcastEpisode, restorePosition: Bool = false, queueInterruptedEpisode: Bool = false,
                        preservingQueue: Bool = false) async throws {
        // Capture the outgoing clock before replacing its item. A pending seek
        // already owns `position` and must not be overwritten by the old clock.
        if !isSelecting, !needsPreparation, pendingSeek == nil, player.currentItem != nil {
            let time = player.currentTime().seconds
            if time.isFinite { position = max(0, time) }
        }
        var interruptedID: String?
        if queueInterruptedEpisode, let currentEpisode, currentEpisode.id != episode.id,
           !isAtEnd, library.state.progress[currentEpisode.id]?.listened != true {
            interruptedID = currentEpisode.id
        }
        let retainedPosition = restorePosition && currentEpisode?.id == episode.id ? position : nil
        persistPosition()
        willPlay?()
        let token = UUID(); generation = token; isSelecting = true
        bufferingTask?.cancel(); bufferingTask = nil
        defer { if generation == token { isSelecting = false; updatePlayback() } }
        clearPlaybackStart()
        player.currentItem?.cancelPendingSeeks()
        player.pause(); player.replaceCurrentItem(with: nil); isPlaying = false; requestedPlayback = true; actualStartRecorded = false; pendingSeek = nil; seekGeneration = UUID(); finishSeek(false)
        errorMessage = nil; setBuffering(true)
        if currentEpisode?.id != episode.id { artwork = nil }
        currentEpisode = episode; duration = downloads.cachedDuration(episode.id) ?? episode.duration
        let saved = library.state.progress[episode.id]
        position = saved?.listened == true ? 0 : max(0, retainedPosition ?? saved?.position ?? 0)
        if isAtEnd { position = 0 }
        rate = library.state.shows[episode.showID]?.settings.playbackRate ?? 1
        let local = downloads.localURL(episode.id)
        let removesQueuedEpisode = !preservingQueue && (library.state.queue.contains(episode.id) || library.state.continuation.contains(episode.id))
        let changesSelection = interruptedID != nil || library.state.currentEpisodeID != episode.id || removesQueuedEpisode || saved?.suppressAutomaticDownload == true ||
            (!restorePosition && saved?.listened == true)
        // Cold Resume usually changes none of these fields. Do not encode and
        // atomically rewrite the whole feed library before opening its audio.
        if changesSelection {
            try library.edit { state in
                state.currentEpisodeID = episode.id
                if !preservingQueue { state.queue.removeAll { $0 == episode.id }; state.continuation.removeAll { $0 == episode.id } }
                if let interruptedID {
                    state.queue.removeAll { $0 == interruptedID }
                    state.queue.insert(interruptedID, at: 0)
                    state.progress[interruptedID]?.suppressAutomaticDownload = false
                }
                state.progress[episode.id]?.suppressAutomaticDownload = false
                if !restorePosition, state.progress[episode.id]?.listened == true {
                    state.progress[episode.id]?.listened = false; state.progress[episode.id]?.completedAt = nil
                }
            }
        }
        if local == nil || changesSelection { Task { await self.downloads.reconcile() } }
        let audio = AVAudioSession.sharedInstance()
        // Playback already supports AirPlay. Explicit .allowAirPlay is only
        // valid for .playAndRecord and throws paramErr (-50) here.
        try audio.setCategory(.playback, mode: .spokenAudio)
        try audio.setActive(true)
        let cachedDuration = local == nil ? nil : downloads.cachedDuration(episode.id)
        let asset = installItem(episode, url: local ?? episode.mediaURL, token: token)
        publish()
        // RSS durations can be missing or inaccurate. Resolve the actual end
        // before restoring a saved seek so an EOF position cannot stall startup.
        if restorePosition, position > 0 {
            if let cachedDuration { duration = cachedDuration }
            else {
                let length = try? await asset.load(.duration)
                guard token == generation else { throw CancellationError() }
                if let seconds = length?.seconds, seconds.isFinite, seconds > 0 {
                    duration = seconds
                    if local != nil { downloads.cacheDuration(seconds, for: episode.id) }
                }
            }
            if isAtEnd {
                if !preservingQueue, library.state.queue.contains(where: { library.state.episodes[$0] != nil }) {
                    try await advanceCompleted(autoplay: requestedPlayback, natural: false); return
                }
                position = 0; pendingSeek = 0
            }
        }
        // Controls can seek while the item/session is preparing. Only the latest
        // target may win; periodic callbacks must not overwrite it in the meantime.
        repeat {
            let revision = seekGeneration
            let target = pendingSeek ?? position
            var finished = true
            if target > 0 || pendingSeek != nil { finished = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
            guard token == generation else { throw CancellationError() }
            if revision == seekGeneration { pendingSeek = nil; finishSeek(finished); break }
        } while true
        guard token == generation else { throw CancellationError() }
        needsPreparation = false
        if requestedPlayback { startPlayback(); activateSession() }
        loadExtras(episode, token: token)
        publish()
    }
    public func resume() async throws {
        playbackRevision = UUID()
        try await resume(preservingQueue: false)
    }
    private func resume(preservingQueue: Bool) async throws {
        guard let episode = currentEpisode ?? library.state.queue.compactMap({ library.state.episodes[$0] }).first else { return }
        if isAtEnd {
            if !preservingQueue, library.state.queue.contains(where: { library.state.episodes[$0] != nil }) {
                try await advanceCompleted(autoplay: true, natural: false); return
            }
            position = 0
            try await select(episode, preservingQueue: preservingQueue); return
        }
        if try resumePreparedEpisode(episode) { return }
        try await select(episode, restorePosition: true, preservingQueue: preservingQueue)
    }
    private func resumePreparedEpisode(_ episode: PodcastEpisode) throws -> Bool {
        // A streaming item may have been downloaded while paused. Resume from
        // the complete local asset so reconnecting never requires publisher I/O.
        let local = downloads.localURL(episode.id)
        let switchToLocal = local != nil && (player.currentItem?.asset as? AVURLAsset)?.url != local
        guard !isAtEnd, player.currentItem != nil, player.currentItem?.status != .failed,
              !isSelecting, !needsPreparation, !switchToLocal else { return false }
        willPlay?()
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try AVAudioSession.sharedInstance().setActive(true)
        requestedPlayback = true; errorMessage = nil; setBuffering(true)
        startPlayback(); activateSession()
        if extrasTask == nil { loadExtras(episode, token: generation) }
        publish()
        return true
    }
    /// Resume without editing Up Next, returning only once audio starts.
    /// Optionally leave that session paused so headphones can resume it later.
    public func resumeLastPodcast(pauseImmediately: Bool = false) async throws {
        logState(pauseImmediately ? "intent.prime" : "intent.resume")
        try Task.checkCancellation()
        if pauseImmediately, retainsPlaybackSession, session.isActive,
           player.currentItem != nil, player.currentItem?.status != .failed,
           !isSelecting, !needsPreparation,
           !AVAudioSession.sharedInstance().isOtherAudioPlaying {
            // A repeated automation can arrive while the first invocation is
            // still priming. Its temporary audio must be rewound too.
            if primingPlaybackRevision == playbackRevision {
                try await pauseAfterPriming()
            } else { pause() }
            return
        }
        let revision = UUID(); playbackRevision = revision
        if pauseImmediately { primingPlaybackRevision = revision }
        defer { if primingPlaybackRevision == revision { primingPlaybackRevision = nil } }
        let store = try library.requireStore()
        if store.state.naturallyExhaustedQueue { await library.refresh(force: true) }
        try Task.checkCancellation()
        guard playbackRevision == revision else { throw CancellationError() }
        switch PodcastPolicies.resumeDecision(store.state) {
        case .nothing: return
        case .resume(let id):
            guard let episode = store.state.episodes[id] else { return }
            do {
                if currentEpisode?.id == id { try await resume(preservingQueue: true) }
                else { try await select(episode, restorePosition: true, preservingQueue: true) }
            } catch { fail(error); throw error }
        case .start(let id):
            guard let episode = store.state.episodes[id] else { return }
            // The intent selects one episode without the queue edits performed
            // by an explicit episode tap. Completion consumes it from Up Next.
            do { try await select(episode, preservingQueue: true) } catch { fail(error); throw error }
        }
        try await waitForPlaybackSession(pauseImmediately: pauseImmediately, revision: revision)
    }
    private func waitForPlaybackSession(pauseImmediately: Bool, revision: UUID) async throws {
        var itemGeneration = generation
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var playingSince: ContinuousClock.Instant?
        do {
            while true {
                try Task.checkCancellation()
                guard playbackRevision == revision else { throw CancellationError() }
                if let errorMessage { throw PodcastError(errorMessage) }
                // Natural queue advancement belongs to this request. Give its
                // new item a fresh handoff window; explicit transport actions
                // supersede the request through playbackRevision instead.
                if generation != itemGeneration {
                    itemGeneration = generation
                    playingSince = nil
                }
                guard requestedPlayback else {
                    // Native/system controls can pause AVPlayer without a new
                    // Luna transport revision. Finish the prime's rewind before
                    // returning, even when its handoff window was cut short.
                    if pauseImmediately {
                        try await pauseAfterPriming()
                        logState("intent.complete")
                        return
                    }
                    throw CancellationError()
                }
                // isActive only selects a session *within this app*. A first
                // clock tick can precede audio output and system registration.
                // Priming needs a continuous playback window, including the
                // route's output latency, before pausing.
                if isPlaying, session.isActive {
                    let now = ContinuousClock.now
                    let since = playingSince ?? now
                    playingSince = since
                    let audio = AVAudioSession.sharedInstance()
                    let latency = audio.outputLatency + audio.ioBufferDuration
                    let handoff = Duration.seconds(latency.isFinite ? max(3, latency) : 3)
                    if !pauseImmediately || now - since >= handoff {
                        retainsPlaybackSession = true
                        if pauseImmediately {
                            try await pauseAfterPriming()
                        }
                        logState("intent.complete")
                        return
                    }
                } else { playingSince = nil }
                guard ContinuousClock.now < deadline else {
                    throw PodcastError("Unable to prepare podcast playback. Try resuming again.")
                }
                activateSession()
                try await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            // A later transport action owns its own state. Never let an older
            // shortcut pause a replacement episode or a newer Play request.
            if playbackRevision == revision {
                if error is CancellationError {
                    if pauseImmediately {
                        try await pauseAfterPriming()
                    } else { pause() }
                } else { fail(error) }
            }
            throw error
        }
    }
    private func pauseAfterPriming() async throws {
        // Pausing removes background audio execution. Keep the app alive until
        // AVPlayer has completed the rewind and the restored offset is saved.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Restore podcast position", expirationHandler: nil)
        defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
        let resumePosition = playbackResumePosition
        pause()
        let revision = playbackRevision
        // Finish cleanup even if the intent is cancelled after pausing. A new
        // user transport still supersedes this restore through its revision.
        try await Task { @MainActor in
            guard self.playbackRevision == revision else { throw CancellationError() }
            try await self.restorePositionAfterPriming(resumePosition)
        }.value
    }
    private func restorePositionAfterPriming(_ seconds: Double) async throws {
        var finished: Bool?
        seek(to: seconds) { finished = $0 }
        let revision = playbackRevision
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while finished == nil, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard playbackRevision == revision else { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
        guard playbackRevision == revision else { throw CancellationError() }
        guard finished == true else { throw PodcastError("Unable to restore the podcast position. Try seeking back.") }
    }
    func relinquishPlaybackSession() { retainsPlaybackSession = false }
    public func pause() {
        remotePlaybackTask?.cancel()
        playbackRevision = UUID()
        if !isSelecting, !needsPreparation, pendingSeek == nil, player.currentItem != nil {
            let time = player.currentTime().seconds
            if time.isFinite { position = max(0, time) }
        }
        sessionActivation.cancel(); clearPlaybackStart()
        requestedPlayback = false; player.pause(); isPlaying = false; setBuffering(false)
        if isSelecting { generation = UUID(); seekGeneration = UUID(); pendingSeek = nil; finishSeek(false); isSelecting = false; needsPreparation = true; player.currentItem?.cancelPendingSeeks(); extrasTask?.cancel(); extrasTask = nil; extrasTimeoutTask?.cancel(); isLoadingTranscript = false; isLoadingChapters = false }
        persistPosition(); publish()
        logState("pause")
    }
    public func toggle() { if requestedPlayback { pause() } else { _ = handleRemotePlay() } }
    @discardableResult func handleRemotePlay() -> MPRemoteCommandHandlerStatus {
        guard hasRestorableQueue else { return .noActionableNowPlayingItem }
        logState("remote.play")
        remotePlaybackTask?.cancel()
        let revision = UUID(); remotePlaybackRevision = revision
        // Claim the request synchronously so a cancelled older task cannot
        // pause it before this task gets its first turn on the main actor.
        let expectedPlaybackRevision = UUID(); playbackRevision = expectedPlaybackRevision
        // A remote-command handler is synchronous, but a cold/local-switch
        // resume can seek asynchronously. Keep the background app running
        // until audio really starts instead of returning success and suspending
        // before the scheduled Task can finish.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Resume podcast") { [weak self] in
            Task { @MainActor in
                guard let self, self.remotePlaybackRevision == revision else { return }
                self.remotePlaybackTask?.cancel()
            }
        }
        // A prepared item can start synchronously. The system must observe the
        // Play request before its remote-command callback acknowledges success.
        let resumed: Bool
        do { resumed = try currentEpisode.map { try resumePreparedEpisode($0) } ?? false }
        catch {
            if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
            fail(error)
            return .commandFailed
        }
        remotePlaybackTask = Task { [weak self] in
            defer { if background != .invalid { UIApplication.shared.endBackgroundTask(background) } }
            guard let self else { return }
            defer { if remotePlaybackRevision == revision { remotePlaybackTask = nil } }
            do {
                try Task.checkCancellation()
                guard playbackRevision == expectedPlaybackRevision else { throw CancellationError() }
                if !resumed { try await resume(preservingQueue: false) }
                try await waitForPlaybackSession(pauseImmediately: false, revision: expectedPlaybackRevision)
                logState("remote.play.complete")
            } catch is CancellationError { }
            catch { fail(error) }
        }
        return .success
    }
    private var isAtEnd: Bool { duration.isFinite && duration > 0 && position >= duration - 0.05 }
    public func seek(to seconds: Double, completion: ((Bool) -> Void)? = nil) {
        guard seconds.isFinite, let episode = currentEpisode else { completion?(false); return }
        playbackRevision = UUID()
        finishSeek(false); seekCompletion = completion
        let target = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        position = target; pendingSeek = target
        let revision = UUID(); seekGeneration = revision
        // Seeking a restored, unprepared item must survive the next Resume too.
        do {
            try library.edit { state in
                var progress = state.progress[episode.id] ?? PodcastEpisodeState()
                progress.position = target; progress.updatedAt = Date()
                if !isAtEnd { progress.listened = false; progress.completedAt = nil }
                state.progress[episode.id] = progress
                state.currentEpisodeID = episode.id
            }
        }
        catch { errorMessage = error.localizedDescription }
        publish()
        if isAtEnd {
            pendingSeek = nil; finishSeek(false)
            let autoplay = requestedPlayback
            let token = generation
            Task {
                guard generation == token, seekGeneration == revision else { return }
                do { try await advanceCompleted(autoplay: autoplay && requestedPlayback, natural: false) } catch { fail(error) }
            }
            return
        }
        guard !isSelecting else { return }
        guard player.currentItem != nil, !needsPreparation else { finishSeek(true); return }
        if requestedPlayback { playbackStartTime = target; setBuffering(true) }
        let token = generation
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.generation == token, self.seekGeneration == revision else { return }
                self.pendingSeek = nil
                if finished {
                    self.position = target
                    self.persistPosition()
                    if self.requestedPlayback { self.startPlayback() }
                } else { self.errorMessage = "Unable to seek. Try moving the playback position again." }
                self.updatePlayback()
                self.finishSeek(finished)
            }
        }
    }
    public func skip(backward: Bool, completion: ((Bool) -> Void)? = nil) {
        seek(to: position + (backward ? -library.state.settings.skipBack : library.state.settings.skipForward), completion: completion)
    }
    public func setRate(_ value: Float) {
        guard value.isFinite, (0.5...3).contains(value) else { return }
        rate = value
        if requestedPlayback, !isSelecting, pendingSeek == nil { player.playImmediately(atRate: value) }
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
    private func tick() {
        guard !isSelecting, !needsPreparation, !isCompleting, pendingSeek == nil, player.currentItem != nil else { return }
        // Read the current item now: a queued periodic callback can belong to an
        // earlier seek/item and carry an obsolete time.
        let currentTime = player.currentTime().seconds
        if currentTime.isFinite { position = max(0, currentTime) }
        if requestedPlayback, playbackStartTime != nil { updatePlayback() }
        if let length = player.currentItem?.duration.seconds, length.isFinite { duration = max(0, length) }
        if requestedPlayback, actualStartRecorded, isAtEnd {
            let token = generation
            Task { if self.generation == token { await self.ended() } }; return
        }
        if requestedPlayback, Date().timeIntervalSince(lastPersistedAt) >= 5 { persistPositionInBackground(); publish() }
    }
    private func updatePlayback() {
        if !isSelecting, !needsPreparation, pendingSeek == nil, player.currentItem != nil {
            let time = player.currentTime().seconds
            if time.isFinite { position = max(0, time) }
            if let length = player.currentItem?.duration.seconds, length.isFinite, length > 0 { duration = length }
        }
        if player.timeControlStatus == .playing, !requestedPlayback, !isSelecting, !needsPreparation {
            // AVPlayerViewController's video Play button bypasses our transport.
            requestedPlayback = true; willPlay?()
        }
        // System/native video controls can pause AVPlayer directly. Do not
        // leave a pending Play intent that can restart it after a later seek.
        if requestedPlayback, actualStartRecorded, !isSelecting, pendingSeek == nil,
           player.timeControlStatus == .paused, !isAtEnd, !isBuffering {
            requestedPlayback = false
            persistPosition()
        }
        if let start = playbackStartTime, !isSelecting, pendingSeek == nil,
           player.timeControlStatus == .playing, player.currentTime().seconds > start + 0.001 {
            clearPlaybackStart()
        }
        isPlaying = requestedPlayback && player.timeControlStatus == .playing && playbackStartTime == nil
        if isPlaying { activateSession() }
        setBuffering(requestedPlayback && (isSelecting || !isPlaying))
        if isPlaying, !actualStartRecorded, let episode = currentEpisode {
            do { try library.requireStore().recordPlaybackStarted(episode.id); actualStartRecorded = true; library.reloadState() }
            catch { fail(error); return }
        }
        if isPlaying, session.isActive { retainsPlaybackSession = true }
        publish()
    }
    private func setBuffering(_ value: Bool) {
        if isBuffering != value { isBuffering = value }
        if !value { bufferingTask?.cancel(); bufferingTask = nil; return }
        guard bufferingTask == nil else { return }
        bufferingTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard !Task.isCancelled, let self, self.isBuffering, self.requestedPlayback else { return }
            self.fail(PodcastError("This episode is taking too long to load. Check your connection and tap Play to retry."))
        }
    }
    private func ended() async {
        guard requestedPlayback, actualStartRecorded, !isSelecting, pendingSeek == nil else { return }
        do { try await advanceCompleted(autoplay: true, natural: true) } catch { fail(error) }
    }
    private func advanceCompleted(autoplay: Bool, natural: Bool) async throws {
        guard !isCompleting, let episode = currentEpisode else { return }
        isCompleting = true
        defer { isCompleting = false }
        let token = UUID(); generation = token; seekGeneration = UUID(); pendingSeek = nil; finishSeek(false)
        let sleepAtEnd = sleepAtEpisodeEnd
        let shouldPlay = autoplay && !sleepAtEnd
        clearPlaybackStart()
        persistPosition(); requestedPlayback = false; isPlaying = false; setBuffering(false)
        player.pause(); player.replaceCurrentItem(with: nil); needsPreparation = true
        actualStartRecorded = false
        let store = try library.requireStore()
        let next: String?
        if store.state.currentEpisodeID != episode.id { try library.edit { $0.currentEpisodeID = episode.id } }
        if sleepAtEnd {
            try store.markListened(episode.id, true)
            try library.edit { $0.currentEpisodeID = nil; $0.naturallyExhaustedQueue = natural && $0.queue.isEmpty }
            next = nil; sleepAtEpisodeEnd = false
        } else {
            // A manual seek may complete an explicit queue item, but cannot
            // authorize the resume intent's natural-exhaustion recommendations.
            next = try store.finishNaturally(episode.id, natural: natural)
            library.reloadState()
        }
        downloads.remove(episode.id)
        Task { await self.downloads.reconcile() }
        guard generation == token else { return }
        if let next, let episode = library.state.episodes[next] {
            if shouldPlay { try await select(episode) }
            else {
                currentEpisode = episode; duration = downloads.cachedDuration(episode.id) ?? episode.duration
                position = library.state.progress[episode.id]?.listened == true ? 0 : library.state.progress[episode.id]?.position ?? 0
                rate = library.state.shows[episode.showID]?.settings.playbackRate ?? 1
                chapters = episode.chapters; transcript = []; artwork = nil
                extrasTask?.cancel(); extrasTimeoutTask?.cancel(); extrasTask = nil
                isLoadingTranscript = false; isLoadingChapters = false
                publish()
            }
        } else { position = duration; publish() }
    }
    private func persistPositionInBackground() {
        guard positionSaveTask == nil, let id = currentEpisode?.id, actualStartRecorded else { return }
        let savedPosition = position, expected = library.state.progress[id]
        lastPersistedAt = Date()
        positionSaveTask = Task { [weak self] in
            guard let self else { return }
            defer { positionSaveTask = nil }
            do {
                try await library.requireStore().updateInBackground(positionOnly: true) { state in
                    // A seek, pause or completion may have saved newer progress
                    // while this snapshot was encoding. Never rewind that edit.
                    guard state.progress[id] == expected else { return }
                    var progress = state.progress[id] ?? PodcastEpisodeState()
                    progress.position = max(0, savedPosition); progress.updatedAt = Date()
                    state.progress[id] = progress
                }
                library.reloadState()
            } catch is CancellationError { }
            catch { errorMessage = error.localizedDescription }
        }
    }
    public func persistPosition() {
        positionSaveTask?.cancel()
        guard let id = currentEpisode?.id, actualStartRecorded else { return }
        do { try library.requireStore().recordPosition(id, position: position); library.reloadState(); lastPersistedAt = Date() }
        catch { errorMessage = error.localizedDescription }
    }
    public func fail(_ error: Error) {
        guard !(error is CancellationError) else { return }
        let failure = error as NSError
        log.error("failure domain=\(failure.domain, privacy: .public) code=\(failure.code)")
        sessionActivation.cancel(); clearPlaybackStart()
        generation = UUID(); seekGeneration = UUID(); pendingSeek = nil; finishSeek(false); isSelecting = false; needsPreparation = true
        player.currentItem?.cancelPendingSeeks()
        extrasTask?.cancel(); extrasTimeoutTask?.cancel()
        if isLoadingTranscript { transcriptError = error.localizedDescription }
        if isLoadingChapters { chaptersError = error.localizedDescription }
        isLoadingTranscript = false; isLoadingChapters = false
        requestedPlayback = false; player.pause(); isPlaying = false; setBuffering(false)
        errorMessage = error.localizedDescription; publish()
    }
    private func publish() {
        guard let episode = currentEpisode else { return }
        let show = library.state.shows[episode.showID]
        var info: [String: Any] = [MPMediaItemPropertyTitle: episode.title, MPMediaItemPropertyArtist: show?.title ?? "Podcast",
            MPMediaItemPropertyAlbumTitle: show?.title ?? "Podcast",
            MPNowPlayingInfoPropertyDefaultPlaybackRate: rate, MPNowPlayingInfoPropertyExternalContentIdentifier: episode.id,
            MPNowPlayingInfoPropertyMediaType: (episode.isVideo ? MPNowPlayingInfoMediaType.video : .audio).rawValue]
        if let artwork { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork } }
        // Automatic publishing owns elapsed time, duration and playback rate.
        // Writing a competing snapshot to nowPlayingInfoCenter can race a
        // short Play/Pause and leave the system with stale transport state.
        player.currentItem?.nowPlayingInfo = info
        session.remoteCommandCenter.skipBackwardCommand.preferredIntervals = [NSNumber(value: library.state.settings.skipBack)]
        session.remoteCommandCenter.skipForwardCommand.preferredIntervals = [NSNumber(value: library.state.settings.skipForward)]
        NotificationCenter.default.post(name: .lunaPodcastPlaybackChanged, object: self)
    }
    private func logState(_ event: String) {
        log.info("\(event, privacy: .public) requested=\(self.requestedPlayback) playing=\(self.isPlaying) buffering=\(self.isBuffering) playerRate=\(self.player.rate) playerStatus=\(self.player.timeControlStatus.rawValue) appSessionActive=\(self.session.isActive) background=\(UIApplication.shared.applicationState == .background)")
    }
    private func installRemoteCommands() {
        let remote = session.remoteCommandCenter
        func addStatus(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
            command.isEnabled = true
            remoteTargets.append((command, command.addTarget { event in
                MediaRemoteCommandDelivery.perform { action(event) }
            }))
        }
        func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (MPRemoteCommandEvent) -> Void) {
            addStatus(command) { event in action(event); return .success }
        }
        addStatus(remote.playCommand) { [weak self] _ in self?.handleRemotePlay() ?? .commandFailed }
        add(remote.pauseCommand) { [weak self] _ in self?.pause() }
        add(remote.togglePlayPauseCommand) { [weak self] _ in self?.toggle() }
        add(remote.stopCommand) { [weak self] _ in self?.pause() }
        for command in [remote.skipBackwardCommand, remote.previousTrackCommand] {
            add(command) { [weak self] _ in self?.receiveRemoteSkip(.backward) }
        }
        for command in [remote.skipForwardCommand, remote.nextTrackCommand] {
            add(command) { [weak self] _ in self?.receiveRemoteSkip(.forward) }
        }
        add(remote.changePlaybackPositionCommand) { [weak self] event in if let event = event as? MPChangePlaybackPositionCommandEvent { self?.seek(to: event.positionTime) } }
        remote.changePlaybackRateCommand.supportedPlaybackRates = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3]
        add(remote.changePlaybackRateCommand) { [weak self] event in if let event = event as? MPChangePlaybackRateCommandEvent { self?.setRate(event.playbackRate) } }
    }
    public func prepareExtras() {
        guard extrasTask == nil, let episode = currentEpisode else { return }
        loadExtras(episode, token: generation)
    }
    public func retryExtras() {
        guard let episode = currentEpisode else { return }
        loadExtras(episode, token: generation)
    }
    private func loadExtras(_ episode: PodcastEpisode, token: UUID) {
        extrasTask?.cancel(); extrasTimeoutTask?.cancel(); chapters = episode.chapters.isEmpty ? downloads.cachedChapters(episode.id) : episode.chapters; transcript = []
        transcriptError = nil; chaptersError = nil
        isLoadingTranscript = !episode.transcripts.isEmpty
        isLoadingChapters = chapters.isEmpty || episode.chaptersURL != nil
        let asset = player.currentItem?.asset
        extrasTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.generation == token, self.isLoadingTranscript || self.isLoadingChapters else { return }
            if self.isLoadingTranscript { self.transcriptError = "The transcript is taking too long to load. Please try again." }
            if self.isLoadingChapters { self.chaptersError = "The chapters are taking too long to load. Please try again." }
            self.extrasTask?.cancel(); self.isLoadingTranscript = false; self.isLoadingChapters = false
        }
        extrasTask = Task { [weak self] in
            guard let self else { return }
            async let art: Void = loadArtwork(episode, token: token)
            async let text: Void = loadTranscript(episode, token: token)
            async let markers: Void = loadChapters(episode, asset: asset, token: token)
            _ = await (art, text, markers)
        }
    }
    private func extraData(_ url: URL, limit: Int = 5_000_000) async throws -> Data {
        var request = URLRequest(url: url); request.timeoutInterval = 20
        let (data, response) = try await PodcastNetwork.session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw PodcastError("The publisher could not be reached. Please try again.") }
        guard data.count < limit else { throw PodcastError("The publisher’s file is too large.") }
        return data
    }
    private func loadArtwork(_ episode: PodcastEpisode, token: UUID) async {
        guard let url = episode.artworkURL ?? library.state.shows[episode.showID]?.artworkURL,
              let data = try? await extraData(url, limit: 15_000_000), generation == token, !Task.isCancelled else { return }
        artwork = UIImage(data: data); publish()
    }
    private func loadTranscript(_ episode: PodcastEpisode, token: UUID) async {
        defer { if generation == token, !Task.isCancelled { isLoadingTranscript = false } }
        guard let reference = episode.transcripts.first else { return }
        do {
            let cache = PodcastLibraryController.directory.appendingPathComponent("transcript-\(PodcastIdentity.hash(reference.url.absoluteString)).json")
            let cached = await Task.detached { () -> [PodcastTranscriptCue]? in
                guard let data = try? Data(contentsOf: cache) else { return nil }
                return try? JSONDecoder().decode([PodcastTranscriptCue].self, from: data)
            }.value
            if let cues = cached {
                guard generation == token, !Task.isCancelled else { return }; transcript = cues
            } else {
                let data = try await extraData(reference.url)
                // Publisher transcripts can be large; parsing must not block transport/UI.
                let cues = try await Task.detached { try PodcastTranscript.parse(data, type: reference.type) }.value
                guard generation == token, !Task.isCancelled else { return }
                transcript = cues; try? JSONEncoder().encode(cues).write(to: cache, options: [.atomic])
            }
        } catch { if generation == token, !Task.isCancelled { transcriptError = error.localizedDescription } }
    }
    private func loadChapters(_ episode: PodcastEpisode, asset: AVAsset?, token: UUID) async {
        defer { if generation == token, !Task.isCancelled { isLoadingChapters = false } }
        do {
            if let url = episode.chaptersURL {
                struct Document: Decodable { struct Chapter: Decodable { var startTime: Double; var title: String?; var url: String?; var img: String? }; var chapters: [Chapter] }
                let data = try await extraData(url)
                let document = try JSONDecoder().decode(Document.self, from: data)
                guard generation == token, !Task.isCancelled else { return }
                chapters = document.chapters.filter { $0.startTime.isFinite && $0.startTime >= 0 }.map { .init(start: $0.startTime, title: $0.title ?? "Chapter", url: PodcastIdentity.webURL($0.url), imageURL: PodcastIdentity.webURL($0.img)) }.sorted { $0.start < $1.start }
            } else if chapters.isEmpty, let asset {
                let locales = try await asset.load(.availableChapterLocales)
                guard let locale = locales.first else { return }
                let groups = try await asset.loadChapterMetadataGroups(withTitleLocale: locale, containingItemsWithCommonKeys: [.commonKeyTitle])
                var result: [PodcastChapter] = []
                for group in groups {
                    let title = try? await group.items.first?.load(.stringValue)
                    result.append(.init(start: group.timeRange.start.seconds, title: title ?? "Chapter"))
                }
                guard generation == token, !Task.isCancelled else { return }; chapters = result
            }
        } catch { if generation == token, !Task.isCancelled { chaptersError = error.localizedDescription } }
    }
}
