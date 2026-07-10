//
//  NowPlayingCoordinator.swift
//  LunaAudioPlayback
//

import LunaStorage
import MediaPlayer
import UIKit

/// Thin seam over `MPNowPlayingInfoCenter` so `NowPlayingCoordinator`'s info
/// assembly is unit-testable headless (a fake sink records what was pushed;
/// the system sink below forwards to the real center).
public protocol NowPlayingInfoSink: AnyObject {
    var nowPlayingInfo: [String: Any]? { get set }
    func setPlaybackState(isPlaying: Bool)
}

/// Thin seam over `MPRemoteCommandCenter`: registration of targets and
/// enabling/disabling — the two things we do to it — so the coordinator's
/// command handling and enablement policy are testable without the shared
/// system singleton.
public protocol RemoteCommandBinding: AnyObject {
    /// Registers all command targets ONCE, funneling every command into
    /// `handler`. Called exactly once, at app launch (background-relaunch
    /// command delivery requires launch-time registration — see
    /// `claudedocs/audio-playback-plan.md`).
    func bindTargets(handler: @escaping (NowPlayingCoordinator.Command) -> Bool)
    /// Enables/disables the transport commands that are only meaningful with
    /// an active (non-idle) playback session: pause, toggle, skip
    /// forward/backward, change-position. The PLAY command always stays
    /// enabled — when the center is idle it's the cold-relaunch restore
    /// trigger.
    func setTransportCommandsEnabled(_ enabled: Bool)
}

/// Owns `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` for the NEW audio
/// path (`AudioPlaybackCenter`). Registered once at app launch from
/// `AppDelegate` (via `AudioPlaybackWiring.install()` in the app shell).
///
/// LEGACY-CONFLICT HANDOFF (until Phase 3 reroutes the in-app readers): the
/// legacy `LunaReaderUI.SpeechController` also writes `nowPlayingInfo` and —
/// worse — its `setupRemoteCommands()`/`teardownRemoteCommands()` call
/// `removeTarget(nil)` on the shared commands, which strips THIS
/// coordinator's launch-registered targets too. Two guards keep the new path
/// the sole owner whenever it is actually in use:
///   1. Targets are re-asserted (rebound) every time `AudioPlaybackCenter`
///      leaves `.idle`, not only at launch — so even if a legacy in-reader
///      session wiped them, the moment the new center plays anything the
///      system commands are ours again.
///   2. Nothing in-app starts the new center while a legacy session is
///      audible in Phase 2 (the center has no UI yet); Phase 3 completes the
///      handoff by rerouting the readers' footers off `SpeechController`
///      in-app. The share/action extensions keep the legacy path untouched.
public final class NowPlayingCoordinator {
    public static let shared = NowPlayingCoordinator()

    /// A system remote command, reduced to plain values so handling is
    /// testable without `MPRemoteCommandEvent`.
    public enum Command: Equatable {
        case play
        case pause
        case togglePlayPause
        case skipForward(seconds: TimeInterval)
        case skipBackward(seconds: TimeInterval)
        case changePlaybackPosition(seconds: TimeInterval)
    }

    public static let skipForwardInterval: TimeInterval = 30
    public static let skipBackwardInterval: TimeInterval = 15

    private let infoSink: NowPlayingInfoSink
    private let commandBinding: RemoteCommandBinding
    /// Resolves an item's `thumbnailFileName` to a decodable file URL —
    /// injectable for tests; defaults to the shared store's Articles
    /// directory (where `ReadingListStore.setThumbnail` writes).
    private let artworkFileURL: (String) -> URL?

    private weak var center: AudioPlaybackCenter?
    /// Artwork is decoded ONCE per item (keyed by file name) and reused for
    /// every subsequent info push of that item.
    private var cachedArtwork: (fileName: String, artwork: MPMediaItemArtwork)?
    private var lastPeriodicPush = Date.distantPast

    public init(
        infoSink: NowPlayingInfoSink = SystemNowPlayingInfoSink(),
        commandBinding: RemoteCommandBinding = SystemRemoteCommandBinding(),
        artworkFileURL: @escaping (String) -> URL? = { fileName in
            ReadingListStore.shared.articlesDirectory.appendingPathComponent(fileName)
        }
    ) {
        self.infoSink = infoSink
        self.commandBinding = commandBinding
        self.artworkFileURL = artworkFileURL
    }

    /// Call once at app launch: binds the remote-command targets (required
    /// at launch for background-relaunch delivery), observes the center, and
    /// sets the initial (idle) command enablement.
    public func registerAtLaunch(center: AudioPlaybackCenter) {
        self.center = center
        center.addObserver(self)
        bindTargets()
        applyEnablement(for: center.state)
        pushInfo()
    }

    /// Re-asserts our command targets — see the legacy-conflict note above.
    private func bindTargets() {
        commandBinding.bindTargets { [weak self] command in
            self?.handle(command) ?? false
        }
    }

    // MARK: - Command handling (internal so tests can drive it directly)

    func handle(_ command: Command) -> Bool {
        guard let center else { return false }
        switch command {
        case .play:
            switch center.state {
            case .paused:
                center.resume()
                return true
            case .idle:
                // Cold background relaunch: no live session, but a persisted
                // position may exist — restore silently, then the session is
                // already playing (honoring the command).
                return center.restorePersistedSessionIfAvailable()
            case .playing, .announcing:
                return true // already playing
            }
        case .pause:
            center.pause()
            return true
        case .togglePlayPause:
            if case .idle = center.state {
                return center.restorePersistedSessionIfAvailable()
            }
            center.togglePlayPause()
            return true
        case .skipForward(let seconds):
            guard center.state != .idle else { return false }
            center.skip(bySeconds: seconds)
            return true
        case .skipBackward(let seconds):
            guard center.state != .idle else { return false }
            center.skip(bySeconds: -seconds)
            return true
        case .changePlaybackPosition(let seconds):
            guard center.state != .idle else { return false }
            let snapshot = center.currentSnapshot
            guard snapshot.estimatedDuration > 0 else { return false }
            center.seek(toFraction: seconds / snapshot.estimatedDuration)
            return true
        }
    }

    // MARK: - Info publishing

    private func applyEnablement(for state: AudioPlaybackState) {
        commandBinding.setTransportCommandsEnabled(state != .idle)
    }

    /// Pushes the full info dictionary — title/artist/artwork/duration AND
    /// elapsed+rate together, atomically in one `nowPlayingInfo` assignment
    /// (never a partial update that could momentarily pair a new elapsed
    /// with a stale rate or vice versa).
    private func pushInfo() {
        guard let center else { return }
        let snapshot = center.currentSnapshot
        guard let itemInfo = snapshot.itemInfo else {
            infoSink.nowPlayingInfo = nil
            infoSink.setPlaybackState(isPlaying: false)
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: itemInfo.title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPMediaItemPropertyPlaybackDuration: snapshot.estimatedDuration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: snapshot.isAudiblyPlaying ? Double(snapshot.rate) : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if let artist = itemInfo.artist {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let artwork = artwork(for: itemInfo) {
            info[MPMediaItemPropertyArtwork] = artwork
        }
        infoSink.nowPlayingInfo = info
        infoSink.setPlaybackState(isPlaying: snapshot.isAudiblyPlaying)
    }

    private func artwork(for itemInfo: AudioPlaybackItemInfo) -> MPMediaItemArtwork? {
        guard let fileName = itemInfo.thumbnailFileName else { return nil }
        if let cachedArtwork, cachedArtwork.fileName == fileName { return cachedArtwork.artwork }
        guard let url = artworkFileURL(fileName),
              let image = UIImage(contentsOfFile: url.path)
        else { return nil }
        let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        cachedArtwork = (fileName, artwork)
        return artwork
    }
}

extension NowPlayingCoordinator: AudioPlaybackObserver {
    public func audioPlaybackCenter(_ center: AudioPlaybackCenter, didChangeState state: AudioPlaybackState) {
        applyEnablement(for: state)
        if state != .idle {
            // Re-assert command ownership in case a legacy SpeechController
            // session wiped our launch-registered targets (its teardown does
            // `removeTarget(nil)`) — see the legacy-conflict note above.
            bindTargets()
        }
        pushInfo()
    }

    public func audioPlaybackCenter(_ center: AudioPlaybackCenter, didUpdateItem info: AudioPlaybackItemInfo?) {
        pushInfo()
    }

    public func audioPlaybackCenter(
        _ center: AudioPlaybackCenter, didUpdateProgress fraction: Double,
        elapsed: TimeInterval, duration: TimeInterval
    ) {
        // Progress events arrive ~5/sec; the periodic Now Playing push is
        // throttled to ~1/sec (transitions push immediately via
        // didChangeState, which resets nothing here — an extra push is
        // harmless).
        let now = Date()
        guard now.timeIntervalSince(lastPeriodicPush) >= 0.9 else { return }
        lastPeriodicPush = now
        pushInfo()
    }
}

// MARK: - System implementations

/// Forwards to the real `MPNowPlayingInfoCenter`.
public final class SystemNowPlayingInfoSink: NowPlayingInfoSink {
    public init() {}

    public var nowPlayingInfo: [String: Any]? {
        get { MPNowPlayingInfoCenter.default().nowPlayingInfo }
        set { MPNowPlayingInfoCenter.default().nowPlayingInfo = newValue }
    }

    public func setPlaybackState(isPlaying: Bool) {
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }
}

/// Forwards to the real `MPRemoteCommandCenter`.
public final class SystemRemoteCommandBinding: RemoteCommandBinding {
    public init() {}

    public func bindTargets(handler: @escaping (NowPlayingCoordinator.Command) -> Bool) {
        let center = MPRemoteCommandCenter.shared()
        // Remove only OUR previously registered targets before re-adding
        // (bindTargets is re-invoked to re-assert ownership after a legacy
        // SpeechController session) — never stack duplicates.
        removeOwnTargets()

        ownTargets.append((center.playCommand, center.playCommand.addTarget { _ in
            handler(.play) ? .success : .commandFailed
        }))
        ownTargets.append((center.pauseCommand, center.pauseCommand.addTarget { _ in
            handler(.pause) ? .success : .commandFailed
        }))
        ownTargets.append((center.togglePlayPauseCommand, center.togglePlayPauseCommand.addTarget { _ in
            handler(.togglePlayPause) ? .success : .commandFailed
        }))

        center.skipForwardCommand.preferredIntervals = [
            NSNumber(value: NowPlayingCoordinator.skipForwardInterval)]
        ownTargets.append((center.skipForwardCommand, center.skipForwardCommand.addTarget { event in
            let seconds = (event as? MPSkipIntervalCommandEvent)?.interval
                ?? NowPlayingCoordinator.skipForwardInterval
            return handler(.skipForward(seconds: seconds)) ? .success : .commandFailed
        }))
        center.skipBackwardCommand.preferredIntervals = [
            NSNumber(value: NowPlayingCoordinator.skipBackwardInterval)]
        ownTargets.append((center.skipBackwardCommand, center.skipBackwardCommand.addTarget { event in
            let seconds = (event as? MPSkipIntervalCommandEvent)?.interval
                ?? NowPlayingCoordinator.skipBackwardInterval
            return handler(.skipBackward(seconds: seconds)) ? .success : .commandFailed
        }))

        ownTargets.append((center.changePlaybackPositionCommand, center.changePlaybackPositionCommand.addTarget { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return handler(.changePlaybackPosition(seconds: event.positionTime)) ? .success : .commandFailed
        }))
    }

    public func setTransportCommandsEnabled(_ enabled: Bool) {
        let center = MPRemoteCommandCenter.shared()
        // playCommand deliberately stays enabled even when idle — it's the
        // cold-relaunch restore trigger.
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = enabled
        center.togglePlayPauseCommand.isEnabled = enabled
        center.skipForwardCommand.isEnabled = enabled
        center.skipBackwardCommand.isEnabled = enabled
        center.changePlaybackPositionCommand.isEnabled = enabled
    }

    private var ownTargets: [(command: MPRemoteCommand, token: Any)] = []

    private func removeOwnTargets() {
        for (command, token) in ownTargets { command.removeTarget(token) }
        ownTargets = []
    }
}
