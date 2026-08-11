//
//  TimeLimit.swift
//  LunaModels
//

import Foundation

/// A deadline that actually returns at the deadline.
///
/// The obvious spelling is not one. A task group with a second child that sleeps
/// and then `cancelAll()`s —
///
/// ```swift
/// await withTaskGroup(of: T?.self) { group in
///     group.addTask { await operation() }
///     group.addTask { try? await Task.sleep(...); return nil }
///     let first = await group.next() ?? nil
///     group.cancelAll()
///     return first          // ← the group drains HERE
/// }
/// ```
///
/// — reads like a timeout and is not one: a task group awaits **every** child
/// when its scope exits, so `return first` blocks until the losing child also
/// finishes. Cancellation is a request, not a stop, so the "timeout" fires
/// exactly when the work would have returned anyway. Anything that does not
/// poll `Task.isCancelled` — a WebView render, a `withCheckedContinuation` over
/// a completion handler, a loop whose `try? await Task.sleep` swallows the
/// cancellation error and keeps going — makes the cap unbounded.
///
/// This runs the work in an UNSTRUCTURED task instead, so the deadline leg can
/// stop waiting without being able to stop the work. The loser is cancelled and
/// then abandoned: it unwinds on its own time, off the caller's clock.
///
/// (`CaptureIntentFastPath`, in the app shell, is the throwing form of the same
/// race — the App Intent needs to tell a timeout from a failure. This is the
/// library form, where every caller treats "no answer" and "no answer yet" the
/// same way.)
public enum TimeLimit {

    /// Runs `operation`, giving up at `seconds` and returning nil.
    ///
    /// Nil means only that the answer did not arrive in time — the work may
    /// still be running, and callers must treat it as "no answer", never as a
    /// negative one.
    public static func run<T: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let gate = Gate<T>()
        let work = Task { gate.settle(await operation()) }
        let deadline = Task {
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if gate.settle(nil) { work.cancel() }
        }
        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
                gate.attach(continuation)
            }
        } onCancel: {
            // The caller gave up: stop waiting immediately, and pass the
            // cancellation on so the work has its chance to unwind.
            work.cancel()
            if gate.settle(nil) { deadline.cancel() }
        }
        deadline.cancel()
        return result
    }

    /// The one-shot resume the three legs (work, deadline, the caller's own
    /// cancellation) race for. A lock rather than an actor because `onCancel`
    /// runs synchronously and cannot await.
    private final class Gate<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var settled = false
        private var value: T?
        private var continuation: CheckedContinuation<T?, Never>?

        /// Settles the race. Returns whether THIS call was the one that settled
        /// it — which is what makes "cancel the loser exactly once" expressible.
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

        /// Hands the gate the continuation to resume. The race can be settled
        /// before the caller ever suspends (a `seconds` of 0, or work that
        /// returns instantly), so an already-settled gate resumes at once.
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
