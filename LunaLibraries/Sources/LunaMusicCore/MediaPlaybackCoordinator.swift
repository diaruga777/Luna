import Foundation
import Combine
import LunaPodcastCore

@MainActor public final class MediaPlaybackCoordinator: ObservableObject {
    public enum Surface: String { case music, podcasts }
    public static let shared = MediaPlaybackCoordinator()
    @Published public private(set) var active: Surface
    @Published public private(set) var errorMessage: String?
    private var gesture = MediaSkipGesture()
    private var skipRevision = UUID()
    private let uptime: () -> TimeInterval
    private let backward: (Surface, @escaping (Bool) -> Void) -> Void
    @Published public private(set) var switching = false
    private var installed = false
    private let music: MusicPlaybackController
    private let podcasts: PodcastPlaybackController
    private let defaults: UserDefaults
    init(music: MusicPlaybackController = .shared, podcasts: PodcastPlaybackController = .shared,
         defaults: UserDefaults = .standard,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         backward: ((Surface, @escaping (Bool) -> Void) -> Void)? = nil) {
        self.music = music; self.podcasts = podcasts; self.defaults = defaults
        self.uptime = uptime
        self.backward = backward ?? { surface, completion in
            if surface == .podcasts { podcasts.skip(backward: true, completion: completion) }
            else { music.previous(completion: completion) }
        }
        active = Surface(rawValue: defaults.string(forKey: "LunaMusic.activeMedia") ?? "") ?? .music
    }
    public func install() {
        guard !installed else { return }; installed = true
        music.willPlay = { [weak self] in self?.activate(.music) }
        music.remoteSkip = { [weak self] direction, _ in self?.skip(direction) }
        podcasts.remoteSkip = { [weak self] direction, _ in self?.skip(direction) }
        podcasts.willPlay = { [weak self] in self?.activate(.podcasts) }
    }
    private func activate(_ surface: Surface) {
        guard active != surface else { return }
        gesture.cancel(); skipRevision = UUID()
        if surface == .music {
            if podcasts.isPlaying || podcasts.isBuffering { podcasts.pause() }
        } else {
            if music.isPlaying || music.isBuffering { music.pause() }
        }
        active = surface; defaults.set(surface.rawValue, forKey: "LunaMusic.activeMedia")
        NotificationCenter.default.post(name: .lunaMediaSurfaceChanged, object: self)
    }
    public var canSwitch: Bool {
        active == .music ? podcasts.hasRestorableQueue : music.hasRestorableQueue
    }
    public func skip(_ direction: MediaSkipGesture.Direction) {
        install()
        guard !switching else { return }
        let revision = UUID(); skipRevision = revision
        let source = active
        for action in gesture.receive(direction, at: uptime(), canSwitch: canSwitch) {
            switch action {
            case .switchQueue: Task { await switchQueue() }
            case .backward:
                backward(source) { [weak self] finished in
                    guard let self, finished, self.skipRevision == revision, self.active == source else { return }
                    self.gesture.backwardCompleted(at: self.uptime())
                }
            case .forward: if active == .podcasts { podcasts.skip(backward: false) } else { music.next() }
            }
        }
    }
    public func switchQueue() async {
        install(); guard !switching else { return }
        gesture.cancel(); skipRevision = UUID()
        switching = true; errorMessage = nil
        defer { switching = false }
        if active == .podcasts { await music.restoreIfNeeded() }
        guard canSwitch else { return }
        let previous = active
        let wasPlaying = previous == .music ? music.isPlaying : podcasts.isPlaying
        do {
            if previous == .music { try await podcasts.resume() }
            else { try await music.resume() }
        } catch {
            errorMessage = error.localizedDescription
            activate(previous)
            if wasPlaying {
                do {
                    if previous == .music { try await music.resume() }
                    else { try await podcasts.resume() }
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }
    public func toggle() async throws {
        install()
        if active == .podcasts {
            if podcasts.isPlaying || podcasts.isBuffering { podcasts.pause() }
            else { try await podcasts.resume() }
        } else {
            if music.isPlaying { music.pause() }
            else { try await music.resume() }
        }
    }
    /// Cancel playback even before audio starts, leaving paused or idle queues untouched.
    public func pause() {
        if active == .podcasts {
            if podcasts.isPlaying || podcasts.isBuffering { podcasts.pause() }
        } else {
            if music.isPlaying || music.isBuffering { music.pause() }
        }
    }
    /// Relative seeking preserves paused playback and never switches queues.
    public func seek(by seconds: TimeInterval, backward: Bool) async throws {
        guard seconds.isFinite, seconds >= 0 else {
            throw MediaSeekError.invalidDuration
        }
        guard seconds > 0 else { return }
        let surface = active
        if surface == .music { await music.restoreIfNeeded() }
        guard active == surface else { throw CancellationError() }
        var finished: Bool?
        let completion: (Bool) -> Void = { finished = $0 }
        let delta = backward ? -seconds : seconds
        if active == .podcasts {
            guard podcasts.hasRestorableQueue else { throw MediaSeekError.failed }
            podcasts.seek(to: podcasts.position + delta, completion: completion)
        } else {
            guard music.hasRestorableQueue else { throw MediaSeekError.failed }
            music.seek(to: music.playbackTime + delta, completion: completion)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while finished == nil, ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
        guard finished == true else { throw MediaSeekError.failed }
    }
}

private enum MediaSeekError: LocalizedError {
    case invalidDuration, failed
    var errorDescription: String? {
        switch self {
        case .invalidDuration: return "Enter a positive number of seconds."
        case .failed: return "Unable to seek. Try again."
        }
    }
}
