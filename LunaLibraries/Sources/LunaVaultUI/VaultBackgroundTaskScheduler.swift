import BackgroundTasks
import Foundation

public enum VaultBackgroundTaskKind: String, CaseIterable, Sendable {
    case importRepair
    case index
    case download
    case upload
    case thumbnailMaintenance
}

public protocol VaultBackgroundTaskSubmitting: Sendable {
    func submit(identifier: String, requiresNetworkConnectivity: Bool,
                requiresExternalPower: Bool, earliestBeginDate: Date?) throws
    func cancel(identifier: String)
}

public struct SystemVaultBackgroundTaskSubmitter: VaultBackgroundTaskSubmitting {
    public init() {}
    public func submit(identifier: String, requiresNetworkConnectivity: Bool,
                       requiresExternalPower: Bool, earliestBeginDate: Date?) throws {
        let request = BGProcessingTaskRequest(identifier: identifier)
        request.requiresNetworkConnectivity = requiresNetworkConnectivity
        request.requiresExternalPower = requiresExternalPower
        request.earliestBeginDate = earliestBeginDate
        try BGTaskScheduler.shared.submit(request)
    }
    public func cancel(identifier: String) {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}

public enum VaultBackgroundTaskError: Error, Equatable, Sendable {
    case duplicate
    case notRegistered
}

/// Schedules bounded, cancellable Vault work. The operation is intentionally
/// injected so import repair/index/download tests can run without BGTask or a
/// network provider. A production operation should only use the local
/// extraction path or an authenticated sync coordinator supplied by the app.
public final class VaultBackgroundTaskScheduler: @unchecked Sendable {
    public let identifierPrefix: String
    private let submitter: VaultBackgroundTaskSubmitting
    private let lock = NSLock()
    private var operations: [VaultBackgroundTaskKind: @Sendable () async -> Bool] = [:]
    private struct ActiveTask {
        let token: UUID
        let task: Task<Bool, Never>
    }
    private var active: [VaultBackgroundTaskKind: ActiveTask] = [:]
    // Reserve a kind before constructing its Task. Swift tasks may start
    // immediately, so checking only `active` leaves a small duplicate-start
    // window during scheduling.
    private var starting: Set<VaultBackgroundTaskKind> = []

    public init(identifierPrefix: String,
                submitter: VaultBackgroundTaskSubmitting = SystemVaultBackgroundTaskSubmitter()) {
        self.identifierPrefix = identifierPrefix
        self.submitter = submitter
    }

    public func register(kind: VaultBackgroundTaskKind,
                         operation: @escaping @Sendable () async -> Bool) {
        lock.withLock { operations[kind] = operation }
    }

    /// Registers a real BGProcessingTask entry point. The task's expiration
    /// handler cancels the same Swift Task returned by `run`.
    public func registerWithSystemScheduler(kind: VaultBackgroundTaskKind) throws {
        let identifier = identifier(for: kind)
        guard lock.withLock({ operations[kind] != nil }) else {
            throw VaultBackgroundTaskError.notRegistered
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            guard let self, let processing = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            processing.expirationHandler = { [weak self] in self?.cancel(kind: kind) }
            let running = self.run(kind: kind)
            Task {
                let success = await running.value
                processing.setTaskCompleted(success: success && !running.isCancelled)
            }
        }
    }

    @discardableResult
    public func schedule(kind: VaultBackgroundTaskKind,
                         requiresNetworkConnectivity: Bool = false,
                         requiresExternalPower: Bool = false,
                         earliestBeginDate: Date? = Date(timeIntervalSinceNow: 15)) throws -> Task<Bool, Never> {
        let operation: (@Sendable () async -> Bool)? = lock.withLock {
            guard let operation = operations[kind], active[kind] == nil, !starting.contains(kind) else { return nil }
            starting.insert(kind)
            return operation
        }
        guard let operation else { throw VaultBackgroundTaskError.duplicate }
        do {
            try submitter.submit(identifier: identifier(for: kind),
                                 requiresNetworkConnectivity: requiresNetworkConnectivity,
                                 requiresExternalPower: requiresExternalPower,
                                 earliestBeginDate: earliestBeginDate)
        } catch {
            lock.withLock { starting.remove(kind) }
            throw error
        }
        return start(kind: kind, operation: operation)
    }

    @discardableResult
    public func run(kind: VaultBackgroundTaskKind) -> Task<Bool, Never> {
        let operation = lock.withLock { () -> (@Sendable () async -> Bool)? in
            guard let operation = operations[kind], active[kind] == nil, !starting.contains(kind) else { return nil }
            starting.insert(kind)
            return operation
        }
        guard let operation else { return Task { false } }
        return start(kind: kind, operation: operation)
    }

    private func start(kind: VaultBackgroundTaskKind,
                       operation: @escaping @Sendable () async -> Bool) -> Task<Bool, Never> {
        let task = Task { await operation() }
        let token = UUID()
        lock.withLock {
            starting.remove(kind)
            active[kind] = ActiveTask(token: token, task: task)
        }
        Task { [weak self] in
            _ = await task.value
            self?.lock.withLock {
                guard self?.active[kind]?.token == token else { return }
                self?.active[kind] = nil
            }
        }
        return task
    }

    public func cancel(kind: VaultBackgroundTaskKind) {
        lock.withLock { active[kind]?.task.cancel() }
        submitter.cancel(identifier: identifier(for: kind))
    }

    public func isRunning(_ kind: VaultBackgroundTaskKind) -> Bool {
        lock.withLock { active[kind] != nil }
    }

    public func identifier(for kind: VaultBackgroundTaskKind) -> String {
        identifierPrefix + "." + kind.rawValue
    }
}
