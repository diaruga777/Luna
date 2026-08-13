//
//  OneShotLatch.swift
//  LunaModels
//

import Foundation

/// A thread-safe one-shot latch: `claim()` returns `true` for exactly one
/// caller, however many race for it, and `false` for everyone after.
///
/// Exists for the three timeout races in the codebase — `IntentIngestHelper
/// .savePressRacingTimeout`, `ArticleExportImages.withTimeout` and
/// `URLRescueEngine.raceAgainstTimeout` — which each start two unstructured
/// tasks and must resume one checked continuation from whichever finishes
/// first. Each used to spell it as a local `var resumed` guarded by its own
/// `NSLock`; that is the same guarantee, but a captured `var` mutated from
/// concurrently-executing tasks is a data race the compiler can only warn
/// about rather than verify. A `Sendable` latch says it in a form it can check,
/// and says it once instead of three times.
public final class OneShotLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    public init() {}

    /// `true` for the first caller only. Safe to call from any thread.
    public func claim() -> Bool {
        lock.withLock {
            if claimed { return false }
            claimed = true
            return true
        }
    }
}
