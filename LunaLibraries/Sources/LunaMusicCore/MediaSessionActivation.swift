import AVFoundation
import MediaPlayer

/// A session may only become eligible after AVPlayer has begun producing audio.
/// Retry on eligibility changes instead of discarding a failed startup attempt.
@MainActor final class MediaSessionActivation: NSObject, MPNowPlayingSessionDelegate {
    private let canBecomeActive: () -> Bool
    private let isActive: () -> Bool
    private let shouldActivate: () -> Bool
    private let activate: () async -> Bool
    private var task: Task<Void, Never>?
    private var revision = UUID()

    convenience init(session: MPNowPlayingSession, shouldActivate: @escaping () -> Bool) {
        self.init(canBecomeActive: { session.canBecomeActive }, isActive: { session.isActive },
                  shouldActivate: shouldActivate, activate: { await session.becomeActiveIfPossible() })
        session.delegate = self
    }

    init(canBecomeActive: @escaping () -> Bool, isActive: @escaping () -> Bool,
         shouldActivate: @escaping () -> Bool, activate: @escaping () async -> Bool) {
        self.canBecomeActive = canBecomeActive; self.isActive = isActive
        self.shouldActivate = shouldActivate; self.activate = activate
    }

    func request() {
        guard task == nil, shouldActivate(), canBecomeActive(), !isActive() else { return }
        let token = UUID(); revision = token
        task = Task { [weak self] in
            guard let self else { return }
            defer { if revision == token { task = nil } }
            guard !Task.isCancelled, shouldActivate() else { return }
            _ = await activate()
        }
    }

    func cancel() { revision = UUID(); task?.cancel(); task = nil }

    nonisolated func nowPlayingSessionDidChangeCanBecomeActive(_ nowPlayingSession: MPNowPlayingSession) {
        Task { @MainActor [weak self] in self?.request() }
    }
}
