//
//  CaptureIntentRuntime+LongRunning.swift
//  Luna
//
//  SaveIntent's guarded iOS 27 runtime, compiled into every app target.
//  MediaIntentHandoff remains a separate, media-target-only composition seam.
//
//  ProvideContext is always a normal AppIntent. It performs a 20 s fast path,
//  then hands actual downloads or unfinished save work to this intent.
//

import AppIntents
import LunaIntents
import LunaStorage
import Foundation

/// Whether this app+OS actually grants the extended runtime — and with it the
/// SYSTEM's own intent progress UI. One condition, two consequences:
///
/// - `MediaIntentHandoff` stands Luna's download Live Activity down for the leg
///   the system already covers ("prefer the system UI");
/// - the save press may wait `IntentSaveTimeout.extendedRuntime` instead of
///   racing the ordinary budget.
enum CaptureIntentExtendedRuntime {
    static var isAvailable: Bool {
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) { return true }
        #endif
        return false
    }

    /// The save-press budget for whichever runtime this run got.
    static var saveTimeout: TimeInterval {
        isAvailable ? IntentSaveTimeout.extendedRuntime : IntentSaveTimeout.standard
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
// iOS 17+, below the iOS 18 deployment target, so no availability gate. Save is
// the only capture intent that can start a Live Activity. Verify the
// conformance survives metadata extraction: `systemProtocols` in
// `<App>.app/Metadata.appintents/extract.actionsdata` must list
// `com.apple.link.systemProtocol.SessionStarting` for SaveIntent.
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
extension SaveIntent: LongRunningIntent, CancellableIntent {}

@available(iOS 27.0, *)
extension LongRunningIntent where Self: CancellableIntent {

    /// Runs `operation` with the extended background runtime, pumping `progress`
    /// from `reporter` once a second for as long as it runs. The heartbeat is not
    /// decoration: a stalled `progress` is grounds for the system to cancel the
    /// extension (see `IntentProgressReporter`).
    ///
    /// `CancellableIntent` is what unlocks the `onCancel:` overload, so the two
    /// ways this run can end early are distinguishable and recorded:
    /// `.userCancelled` (someone dismissed it from the system's progress UI) and
    /// `.timeout` (the system took the runtime back). The handler is SYNCHRONOUS
    /// and fires exactly when our runtime is being revoked, so it only does
    /// bookkeeping — the durable transfer keeps running, and the awaited media
    /// leg hands the progress UI back to Luna's own Live Activity on the way out
    /// (`MediaIntentHandoff`) so a continuing download never goes invisible.
    /// Stopping the transfer is deliberately NOT done here: it is a durable
    /// Downloader job that also feeds the library, and the activity we hand back
    /// carries an explicit Suspend control.
    func performTracked<T>(
        reporter: IntentProgressReporter,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        let progress = self.progress
        progress.totalUnitCount = 1_000
        return try await performBackgroundTask {
            let heartbeat = Task {
                // Once the transfer's size is known, report BYTES: a file-kind
                // `Progress` in bytes is what makes the system render
                // "1.2 MB of 4.4 MB" instead of a percentage of nothing in
                // particular. Until then (and for saves with no download at all)
                // the estimate drives it, which is only ever the 0–2% save band.
                while !Task.isCancelled {
                    reporter.tick()
                    if let bytes = reporter.byteCounts {
                        if progress.totalUnitCount != bytes.expected {
                            progress.kind = .file
                            progress.fileOperationKind = .downloading
                            progress.totalUnitCount = bytes.expected
                        }
                        progress.completedUnitCount = bytes.received
                    } else {
                        progress.completedUnitCount = Int64(reporter.fraction * 1_000)
                    }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            defer { heartbeat.cancel() }
            let value = try await operation()
            progress.completedUnitCount = progress.totalUnitCount
            return value
        } onCancel: { reason in
            SharedDiagnosticLog.record(
                "capture intent runtime ended early: \(reason.debugDescription)",
                category: "intents")
        }
    }
}

#endif

// MARK: - The concrete override

// This shadows `CaptureIntentRuntime`'s inline default on Save's concrete type,
// so `perform()` reads the same in every app while the runtime differs by
// compiler/OS availability. Written on the intent rather than in one protocol
// extension because `performBackgroundTask` resolves against the concrete type.

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

    var captureSaveTimeout: TimeInterval { CaptureIntentExtendedRuntime.saveTimeout }
}
