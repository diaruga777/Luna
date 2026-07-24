//
//  CaptureIntentRuntime+LongRunning.swift
//  Luna
//
//  The MEDIA-HANDLING apps' capture runtime — compiled only into Luna Downloader
//  and the central Luna app (excluded from Reader / Price Tracker via the
//  synchronized group's membership exceptions, exactly like MediaIntentHandoff).
//
//  Only these two need it. A Reader or Price Tracker capture ends at the save and
//  fits the ordinary ~30 s background budget; a media capture spends 12 s on the
//  save race, then a 20 s preflight HEAD, then an awaited transfer — and would be
//  killed mid-download having reported nothing.
//

import AppIntents
import Foundation

/// Whether this app+OS hands progress to the SYSTEM's own intent progress UI.
/// `MediaIntentHandoff` consults it to stand Luna's download Live Activity down
/// for the leg the system already covers — "prefer the system UI".
enum CaptureIntentSystemProgress {
    static var isAvailable: Bool {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { return true }
        #endif
        return false
    }
}

// MARK: - Starting a Live Activity from the background

// `LiveActivityIntent` is what PERMITS the media download's Live Activity to
// start at all: "In general, your app needs to be in the foreground to start a
// Live Activity. However, you can use a `LiveActivityIntent` and start the Live
// Activity in its `perform()` method." Without it `Activity.request` throws for
// every background Action Button run and the transfer proceeds invisibly — the
// `catch` in `startActivity` logs "live activity request failed" and moves on.
//
// iOS 17+, below the iOS 18 deployment target, so no availability gate. Scoped to
// these two apps because they are the only ones that start a Live Activity from
// an intent. Verify it survives metadata extraction: `systemProtocols` in
// `Luna.app/Metadata.appintents/extract.actionsdata` must list
// `com.apple.link.systemProtocol.SessionStarting` for both intents.
extension ProvideContextIntent: LiveActivityIntent {}
extension SaveIntent: LiveActivityIntent {}

// MARK: - Extended background runtime

#if compiler(>=6.4)

// `LongRunningIntent` lifts the ~30 s ceiling for as long as the intent keeps
// reporting progress. TWO gates, both required:
//
// - `#if compiler(>=6.4)` — the protocol is ABSENT from iPhoneOS26.2.sdk
//   (verified: 0 occurrences in its AppIntents swiftinterface, 2 in the iOS 27
//   SDK), so a stable-Xcode archive must not even name it. Same seam shape as
//   `FoundationModelsScreenCaptureSession`. Consequence: builds archived with
//   Xcode 26.2 fall back to the ordinary budget and keep Luna's own Live
//   Activity, exactly as they compile the vision-session stub.
// - `@available(iOS 27, *)` — the conformance is compiled in unconditionally
//   (Swift conformances aren't availability-checked at runtime), but its
//   extension methods exist only on iOS 27+.

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

// MARK: - The per-target override

// These shadow `CaptureIntentRuntime`'s inline default on the concrete type, so
// `perform()` reads the same in every app while the runtime differs by target
// membership. Written per intent rather than in one protocol extension because
// `performBackgroundTask` resolves against the concrete conforming type.

extension ProvideContextIntent {
    func withCaptureRuntime<T>(
        reporter: IntentProgressReporter,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            return try await performTracked(reporter: reporter, operation: operation)
        }
        #endif
        return try await operation()
    }
}

extension SaveIntent {
    func withCaptureRuntime<T>(
        reporter: IntentProgressReporter,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            return try await performTracked(reporter: reporter, operation: operation)
        }
        #endif
        return try await operation()
    }
}
