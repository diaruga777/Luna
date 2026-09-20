//
//  RescueTimeout.swift
//  LunaURLRescue
//

import Foundation
import LunaModels

/// Races `work` against `seconds` on UNSTRUCTURED tasks, resuming on whichever
/// finishes first; nil means the timeout won.
///
/// Deliberately NOT a task group. A group does not return until every child has
/// finished, and `cancelAll()` only REQUESTS cancellation — so a single
/// cancellation-deaf child hangs the group and, with it, the very timeout meant
/// to bound it. A `LanguageModelSession.respond` that never comes back is
/// exactly such a child, which is what left the failed-save card stuck on
/// "Asking Apple Intelligence" forever instead of giving up after 90 s. Same
/// reasoning and the same shape as `IntentIngestHelper.savePressRacingTimeout`,
/// which carries this warning for the same reason.
func raceAgainstTimeout<T>(
    seconds: TimeInterval, _ work: @escaping () async -> T
) async -> T? {
    let resumeLatch = OneShotLatch()
    return await withCheckedContinuation { continuation in
        @Sendable func finish(_ value: T?) {
            if resumeLatch.claim() { continuation.resume(returning: value) }
        }
        Task { finish(await work()) }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            finish(nil)
        }
    }
}
