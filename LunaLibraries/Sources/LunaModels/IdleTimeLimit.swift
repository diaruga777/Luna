//
//  IdleTimeLimit.swift
//  LunaModels
//

import Foundation

/// A timeout that measures silence rather than total wall-clock time.
///
/// The work runs in an unstructured task for the same reason as `TimeLimit`:
/// leaving a task group waits for every child, including a continuation or
/// framework call that ignores cancellation. Activity resets the deadline, so a
/// slow transfer can keep running while bytes arrive; thirty seconds with no
/// progress still returns promptly and cancels the losing task.
public enum IdleTimeLimit {

    /// A thread-safe heartbeat that can also be handed to callback-driven APIs
    /// (WebKit delegates, URLSession task polling) outside the operation's task
    /// tree.
    public final class Activity: @unchecked Sendable {
        private let lock = NSLock()
        private var lastActivity = DispatchTime.now().uptimeNanoseconds

        public init() {}

        public func touch() {
            lock.withLock { lastActivity = DispatchTime.now().uptimeNanoseconds }
        }

        fileprivate func remaining(seconds: TimeInterval) -> TimeInterval {
            let last = lock.withLock { lastActivity }
            let now = DispatchTime.now().uptimeNanoseconds
            let elapsedNanoseconds = now >= last ? now - last : 0
            return max(0, seconds - TimeInterval(elapsedNanoseconds) / 1_000_000_000)
        }
    }

    /// The heartbeat for the operation currently running under an idle limit.
    /// Nested limits reuse it by default, so a pipeline's inner network progress
    /// also keeps its outer bulk-import watchdog alive.
    @TaskLocal public static var activity: Activity?

    /// Records useful progress when an idle-limited operation is active.
    public static func touch() { activity?.touch() }

    /// Runs `operation`, returning nil after `seconds` without a heartbeat.
    ///
    /// Supplying `activity` lets callback-driven work report progress explicitly.
    /// With no supplied heartbeat, a nested call reuses the ambient one; only the
    /// outermost call creates a new heartbeat.
    public static func run<T: Sendable>(
        _ seconds: TimeInterval,
        activity suppliedActivity: Activity? = nil,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let heartbeat = suppliedActivity ?? activity ?? Activity()
        let gate = Gate<T>()
        let work = Task {
            let value = await $activity.withValue(heartbeat) { await operation() }
            gate.settle(value)
        }
        let deadline = Task {
            while !Task.isCancelled {
                let remaining = heartbeat.remaining(seconds: max(0, seconds))
                if remaining <= 0 {
                    if gate.settle(nil) { work.cancel() }
                    return
                }
                do {
                    try await Task.sleep(
                        nanoseconds: UInt64(remaining * 1_000_000_000))
                } catch {
                    return
                }
            }
        }

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                gate.attach(continuation)
            }
        } onCancel: {
            work.cancel()
            if gate.settle(nil) { deadline.cancel() }
        }
        deadline.cancel()
        return result
    }

    private final class Gate<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var settled = false
        private var value: T?
        private var continuation: CheckedContinuation<T?, Never>?

        @discardableResult
        func settle(_ result: T?) -> Bool {
            lock.lock()
            guard !settled else {
                lock.unlock()
                return false
            }
            settled = true
            value = result
            let waiting = continuation
            continuation = nil
            lock.unlock()
            waiting?.resume(returning: result)
            return true
        }

        func attach(_ continuation: CheckedContinuation<T?, Never>) {
            lock.lock()
            if settled {
                let result = value
                lock.unlock()
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}
