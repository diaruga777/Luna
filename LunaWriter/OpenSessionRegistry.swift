import Foundation
import LunaWriterEditor
import LunaWriterModels
import LunaWriterStorage

/// The sessions currently open in editors, held weakly. The reconciler asks it
/// before adopting an external change, and the app flushes them on background.
@MainActor final class OpenSessionRegistry: OpenDocumentQuerying {
    /// How often the dirty-id snapshot below is refreshed while sessions are
    /// open. A test can shrink this to avoid waiting out the production value.
    static var snapshotRefreshInterval: TimeInterval = 0.25

    private var sessions: [DocumentID: WeakSession] = [:]
    private let snapshotLock = NSLock()
    private var unsavedSnapshot: Set<DocumentID> = []
    private var refreshTimer: Timer?

    func register(_ session: DocumentSession) {
        sessions[session.document.id] = WeakSession(session)
        prune()
        refreshSnapshot()
        startTimerIfNeeded()
    }

    var openSessions: [DocumentSession] {
        prune()
        return sessions.values.compactMap(\.session)
    }

    /// The watcher's queue asks this off the main thread, once per changed
    /// file on every scan. It answers from a snapshot refreshed on main —
    /// never by hopping onto main itself, which would deadlock against a
    /// `queue.sync` the watcher can be in when the file event fires.
    nonisolated func hasUnsavedEdits(_ id: DocumentID) -> Bool {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return unsavedSnapshot.contains(id)
    }

    func flushAll() {
        for session in openSessions { session.applicationDidEnterBackground() }
        refreshSnapshot()
    }

    /// Recomputes the snapshot `hasUnsavedEdits` reads. Called on main after
    /// anything that can change which sessions are dirty.
    func refreshSnapshot() {
        let dirty = Set(openSessions.filter(\.hasUnsavedChanges).map(\.document.id))
        snapshotLock.lock()
        unsavedSnapshot = dirty
        snapshotLock.unlock()
    }

    private func startTimerIfNeeded() {
        guard refreshTimer == nil else { return }
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.snapshotRefreshInterval, repeats: true
        ) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func tick() {
        prune()
        if sessions.isEmpty {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
        refreshSnapshot()
    }

    private func prune() {
        sessions = sessions.filter { $0.value.session != nil }
    }

    private struct WeakSession {
        weak var session: DocumentSession?
        init(_ session: DocumentSession) { self.session = session }
    }
}
