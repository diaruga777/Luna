//
//  OneShotLatch.swift
//  LunaModels
//

import Synchronization

/// A thread-safe one-shot latch: `claim()` returns `true` for exactly one
/// caller, however many race for it, and `false` for everyone after.
///
/// Exists for the three timeout races in the codebase — `IntentIngestHelper
/// .savePressRacingTimeout`, `ArticleExportImages.withTimeout` and
/// `URLRescueEngine.raceAgainstTimeout` — which each start two unstructured
/// tasks and must resume one checked continuation from whichever finishes
/// first. A local `var resumed` guarded by its own `NSLock` gives the same
/// guarantee, but a captured `var` mutated from concurrently-executing tasks
/// is a data race the compiler can only warn about, not verify.
///
/// The state lives in a `Mutex`, so this class's `Sendable` is CHECKED — the
/// compiler verifies it rather than taking the annotation's word for it. A
/// `Mutex` is non-copyable and so cannot be captured by an escaping closure
/// directly; holding one behind a final class is what lets the racing tasks
/// share it.
public final class OneShotLatch: Sendable {
    private let claimed = Mutex(false)

    public init() {}

    /// `true` for the first caller only. Safe to call from any thread.
    public func claim() -> Bool {
        claimed.withLock { claimed in
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
