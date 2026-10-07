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
    private var switching = false
    private var installed = false
    private init() { active = Surface(rawValue: UserDefaults.standard.string(forKey: "LunaMusic.activeMedia") ?? "") ?? .music }
    public func install() {
        guard !installed else { return }; installed = true
        MusicPlaybackController.shared.willPlay = { [weak self] in self?.activate(.music) }
        MusicPlaybackController.shared.remoteSkip = { direction, timestamp in Self.shared.skip(direction, timestamp: timestamp) }
        PodcastPlaybackController.shared.willPlay = { [weak self] in self?.activate(.podcasts) }
    }
    private func activate(_ surface: Surface) {
        guard active != surface else { return }
        gesture.cancel(); expiration?.cancel()
        if surface == .music { PodcastPlaybackController.shared.pause() }
        else { MusicPlaybackController.shared.pause() }
        active = surface; UserDefaults.standard.set(surface.rawValue, forKey: "LunaMusic.activeMedia")
        NotificationCenter.default.post(name: .lunaMediaSurfaceChanged, object: self)
    }
    public var canSwitch: Bool {
        active == .music ? PodcastPlaybackController.shared.currentEpisode != nil : MusicPlaybackController.shared.hasRestorableQueue
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
            case .backward: if active == .podcasts { PodcastPlaybackController.shared.skip(backward: true) } else { MusicPlaybackController.shared.previous() }
            case .forward: if active == .podcasts { PodcastPlaybackController.shared.skip(backward: false) } else { MusicPlaybackController.shared.next() }
            }
        }
    }
    public func switchQueue() async {
        install(); guard !switching else { return }
        if active == .podcasts { await MusicPlaybackController.shared.restoreIfNeeded() }
        guard canSwitch else { return }
        switching = true; defer { switching = false }
        let previous = active
        let wasPlaying = previous == .music ? MusicPlaybackController.shared.isPlaying : PodcastPlaybackController.shared.isPlaying
        do {
            if previous == .music { try await PodcastPlaybackController.shared.resume() }
            else { try await MusicPlaybackController.shared.resume() }
        } catch {
            errorMessage = error.localizedDescription
            activate(previous)
            if wasPlaying {
                do {
                    if previous == .music { try await MusicPlaybackController.shared.resume() }
                    else { try await PodcastPlaybackController.shared.resume() }
                } catch { errorMessage = error.localizedDescription }
            }
        }
    }
    public func toggle() async throws {
        install()
        if active == .podcasts {
            if PodcastPlaybackController.shared.isPlaying || PodcastPlaybackController.shared.isBuffering { PodcastPlaybackController.shared.pause() }
            else { try await PodcastPlaybackController.shared.resume() }
        } else {
            if MusicPlaybackController.shared.isPlaying { MusicPlaybackController.shared.pause() }
            else { try await MusicPlaybackController.shared.resume() }
        }
    }
    public func pause() { if active == .podcasts { PodcastPlaybackController.shared.pause() } else { MusicPlaybackController.shared.pause() } }
}
