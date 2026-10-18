import Foundation
import LunaCodeCore

actor CodeInstallHandoffGate {
    private var pending: [String: CodeInstallHandoff] = [:]
    func prepare(_ id: String) -> CodeInstallHandoff {
        if let existing = pending[id] { return existing }
        let value = CodeInstallHandoff(); pending[id] = value; return value
    }
    func acknowledge(_ id: String, token: String?) throws -> CodeInstallHandoff {
        guard var value = pending[id], value.token == token else { throw CodeFailure("This update handoff is no longer available. Refresh the build status.") }
        value.acknowledged = true; pending[id] = value; return value
    }
    func cancel(_ id: String) { pending[id] = nil }
    func wait(_ id: String, timeout: TimeInterval = 120) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while true {
            try Task.checkCancellation()
            guard let value = pending[id] else { throw CancellationError() }
            if value.acknowledged { return }
            guard clock.now < deadline else {
                throw CodeFailure("Build completed, but Luna Code did not acknowledge the update handoff. No replacement was installed. Reopen Luna Code and retry Build & Run.")
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
