//
//  IntentExtendedRuntime.swift
//  Luna
//
//  The system's extended background runtime + system progress UI for the two
//  capture intents (`LongRunningIntent`, iOS 27). Everything iOS-27-only lives
//  behind the compiler gate here; the intents themselves stay readable.
//

import AppIntents
import Foundation

/// Whether this build/OS can hand a long intent to the system.
///
/// Without an extension, an app intent gets **~30 s** in the background (Apple's
/// documented figure, stated in `LongRunningIntent`: "the system gives tasks 30
/// seconds to run in the background unless you use the methods of this
/// protocol"). Luna's capture can spend 12 s on the save race before a preflight
/// HEAD (20 s) and an awaited transfer even begin, so a real media capture can
/// hit that ceiling and be killed mid-download — reporting nothing, which is the
/// one thing these intents must never do. `LongRunningIntent` lifts the ceiling
/// for as long as the intent keeps reporting progress, and shows the SYSTEM's own
/// progress UI while it runs.
///
/// TWO gates, both required:
/// - `#if compiler(>=6.4)` — `LongRunningIntent` is **absent from
///   iPhoneOS26.2.sdk** (verified: 0 occurrences in its `AppIntents`
///   swiftinterface, 2 in the iOS 27 SDK), so a stable-Xcode archive must not
///   even name it. Same seam shape as `FoundationModelsScreenCaptureSession`.
///   **Consequence:** builds archived with Xcode 26.2 take the fallback path and
///   keep Luna's own Live Activity, exactly as `visionModelAvailable` is false
///   in those builds.
/// - `@available(iOS 27, *)` — the conformance is compiled in unconditionally
///   (Swift conformances aren't availability-checked at runtime), but its
///   extension methods exist only on iOS 27+.
enum IntentExtendedRuntime {

    /// True when the running OS drives its own progress UI for a long intent.
    /// The media handoff consults this to suppress Luna's download Live Activity
    /// for the leg the system already covers — "prefer the system UI".
    static var providesSystemProgressUI: Bool {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { return true }
        #endif
        return false
    }
}

#if compiler(>=6.4)

@available(iOS 27.0, *)
extension ProvideContextIntent: LongRunningIntent {}

@available(iOS 27.0, *)
extension SaveIntent: LongRunningIntent {}

@available(iOS 27.0, *)
extension LongRunningIntent {

    /// Runs `operation` with the extended background runtime, pumping `progress`
    /// from `reporter` once a second for as long as it runs. The heartbeat is not
    /// decoration: a stalled `progress` is grounds for the system to cancel the
    /// extension (see `IntentProgressReporter`).
    func performTracked<T>(
        reporter: IntentProgressReporter,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        let progress = self.progress
        progress.totalUnitCount = 1_000
        return try await performBackgroundTask {
            let heartbeat = Task {
                while !Task.isCancelled {
                    reporter.tick()
                    progress.completedUnitCount = Int64(reporter.fraction * 1_000)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            defer { heartbeat.cancel() }
            let value = try await operation()
            progress.completedUnitCount = progress.totalUnitCount
            return value
        }
    }
}

#endif
