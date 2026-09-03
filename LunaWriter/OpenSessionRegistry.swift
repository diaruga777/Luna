import Foundation
import LunaWriterEditor
import LunaWriterModels
import LunaWriterStorage

/// The sessions currently open in editors, held weakly. The reconciler asks it
/// before adopting an external change, and the app flushes them on background.
@MainActor final class OpenSessionRegistry: OpenDocumentQuerying {
    private var sessions: [DocumentID: WeakSession] = [:]

    func register(_ session: DocumentSession) {
        sessions[session.document.id] = WeakSession(session)
        prune()
    }

    var openSessions: [DocumentSession] {
        prune()
        return sessions.values.compactMap(\.session)
    }

    nonisolated func hasUnsavedEdits(_ id: DocumentID) -> Bool {
        MainActor.assumeIsolatedIfNeeded {
            sessions[id]?.session?.hasUnsavedChanges ?? false
        }
    }

    func flushAll() {
        for session in openSessions { session.applicationDidEnterBackground() }
    }

    private func prune() {
        sessions = sessions.filter { $0.value.session != nil }
    }

    private struct WeakSession {
        weak var session: DocumentSession?
        init(_ session: DocumentSession) { self.session = session }
    }
}
