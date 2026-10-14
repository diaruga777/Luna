import Foundation
import Combine
import LunaPodcastCore

@MainActor public final class MediaPlaybackCoordinator: ObservableObject {
    public enum Surface: String { case music, podcasts }
    public static let shared = MediaPlaybackCoordinator()
    @Published public private(set) var active: Surface
    @Published public private(set) var errorMessage: String?
    private var gesture = MediaSkipGesture()
    private var expiration: Task<Void, Never>?
    @Published public private(set) var switching = false
    private var installed = false
    private let music: MusicPlaybackController
    private let podcasts: PodcastPlaybackController
    private let defaults: UserDefaults
    init(music: MusicPlaybackController = .shared, podcasts: PodcastPlaybackController = .shared,
         defaults: UserDefaults = .standard) {
        self.music = music; self.podcasts = podcasts; self.defaults = defaults
        active = Surface(rawValue: defaults.string(forKey: "LunaMusic.activeMedia") ?? "") ?? .music
    }
    public func install() {
        guard !installed else { return }; installed = true
        music.willPlay = { [weak self] in self?.activate(.music) }
        music.remoteSkip = { [weak self] direction, timestamp in self?.skip(direction, timestamp: timestamp) }
        podcasts.remoteSkip = { [weak self] direction, timestamp in self?.skip(direction, timestamp: timestamp) }
        podcasts.willPlay = { [weak self] in self?.activate(.podcasts) }
    }
    private func activate(_ surface: Surface) {
        guard active != surface else { return }
        gesture.cancel(); expiration?.cancel()
        if surface == .music { podcasts.pause() }
        else { music.pause() }
        active = surface; defaults.set(surface.rawValue, forKey: "LunaMusic.activeMedia")
        NotificationCenter.default.post(name: .lunaMediaSurfaceChanged, object: self)
    }
    public var canSwitch: Bool {
        active == .music ? podcasts.hasRestorableQueue : music.hasRestorableQueue
    }
    public func skip(_ direction: MediaSkipGesture.Direction, timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        install()
        guard !switching else { return }
        expiration?.cancel()
        let actions = gesture.receive(direction, at: timestamp, canSwitch: canSwitch)
        execute(actions)
        if direction == .backward {
            expiration = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(2010)); guard !Task.isCancelled, let self else { return }; self.execute(self.gesture.expire(at: ProcessInfo.processInfo.systemUptime)) }
                catch {}
            }
        }
    }
    private func execute(_ actions: [MediaSkipGesture.Action]) {
        for action in actions {
            switch action {
            case .switchQueue: Task { await switchQueue() }
            case .backward: if active == .podcasts { podcasts.skip(backward: true) } else { music.previous() }
            case .forward: if active == .podcasts { podcasts.skip(backward: false) } else { music.next() }
            }
        }
    }
    public func switchQueue() async {
        install(); guard !switching else { return }
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
    public func pause() { if active == .podcasts { podcasts.pause() } else { music.pause() } }
}
