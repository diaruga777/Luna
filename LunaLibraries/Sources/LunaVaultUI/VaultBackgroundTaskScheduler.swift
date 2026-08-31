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
    private var cancelledStarting: Set<VaultBackgroundTaskKind> = []

    /// A task is created before it is published in `active`, so it must wait
    /// on this gate before invoking user work. This closes the cancellation
    /// window between Task construction and registration.
    private final class StartGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        private var opened = false
        private var cancelled = false

        func wait() async -> Bool {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    if opened { continuation.resume(returning: !cancelled) }
                    else { self.continuation = continuation }
                }
            }
        }

        func open() {
            lock.withLock {
                guard !opened else { return }
                opened = true
                continuation?.resume(returning: !cancelled)
                continuation = nil
            }
        }

        func cancel() {
            lock.withLock {
                cancelled = true
                if !opened {
                    opened = true
                    continuation?.resume(returning: false)
                    continuation = nil
                }
            }
        }
    }

    public init(identifierPrefix: String,
                submitter: VaultBackgroundTaskSubmitting = SystemVaultBackgroundTaskSubmitter()) {
        self.identifierPrefix = identifierPrefix
        self.submitter = submitter
    }

    public func register(kind: VaultBackgroundTaskKind,
                         operation: @escaping @Sendable () async -> Bool) {
        lock.withLock { operations[kind] = operation }
    }

    /// Runs a delivered `BGProcessingTask` against this kind's registered
    /// operation. The app registers the system identifier exactly once at
    /// launch (`BGTaskScheduler.register` may not be called again, and never
    /// after launch finishes); this method is the launch handler's stable
    /// entry point into whichever scheduler instance is current when the task
    /// fires. The task's expiration handler cancels the same Swift Task
    /// returned by `run`.
    public func handleSystemTask(_ task: BGTask, kind: VaultBackgroundTaskKind) {
        guard let processing = task as? BGProcessingTask else {
            task.setTaskCompleted(success: false)
            return
        }
        processing.expirationHandler = { [weak self] in self?.cancel(kind: kind) }
        let running = run(kind: kind)
        Task {
            let success = await running.value
            processing.setTaskCompleted(success: success && !running.isCancelled)
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

    /// Submits a BGProcessingTask request without starting the operation now.
    /// Use this at app backgrounding: the operation must run only when the
    /// system later delivers the task to `handleSystemTask`, on the system's
    /// own execution budget, not opportunistically in-process where a
    /// suspend mid-work would strand the real delivery with nothing left to
    /// do (`active[kind]` already occupied, so the later system task would
    /// complete immediately without running).
    public func submit(kind: VaultBackgroundTaskKind,
                       requiresNetworkConnectivity: Bool = false,
                       requiresExternalPower: Bool = false,
                       earliestBeginDate: Date? = Date(timeIntervalSinceNow: 15)) throws {
        try submitter.submit(identifier: identifier(for: kind),
                             requiresNetworkConnectivity: requiresNetworkConnectivity,
                             requiresExternalPower: requiresExternalPower,
                             earliestBeginDate: earliestBeginDate)
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
        let gate = StartGate()
        let task = Task {
            await withTaskCancellationHandler(operation: {
                guard await gate.wait(), !Task.isCancelled else { return false }
                return await operation()
            }, onCancel: { gate.cancel() })
        }
        let token = UUID()
        let cancelled = lock.withLock {
            starting.remove(kind)
            active[kind] = ActiveTask(token: token, task: task)
            let value = cancelledStarting.remove(kind) != nil
            return value
        }
        if cancelled { task.cancel() } else { gate.open() }
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
        lock.withLock {
            if let task = active[kind]?.task { task.cancel() }
            else if starting.contains(kind) { cancelledStarting.insert(kind) }
        }
        submitter.cancel(identifier: identifier(for: kind))
    }

    public func isRunning(_ kind: VaultBackgroundTaskKind) -> Bool {
        lock.withLock { active[kind] != nil }
    }

    public func identifier(for kind: VaultBackgroundTaskKind) -> String {
        identifierPrefix + "." + kind.rawValue
    }
}
