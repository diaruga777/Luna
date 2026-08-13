//
//  CaptureIntentRuntime.swift
//  Luna
//
//  Which background runtime SaveIntent runs under: the stable-SDK fallback.
//  `CaptureIntentRuntime+LongRunning.swift` supplies the guarded iOS 27 override
//  in every app target.
//

import AppIntents
import LunaIntents
import Foundation

/// The default Save runtime: runs the body inline, under the ordinary ~30
/// second background budget Apple documents for an app intent.
///
/// Xcode 26.2 cannot name the iOS 27 LongRunningIntent API, so this keeps the
/// stable archive build valid. Every app's Xcode 27 build overrides it with
/// `CaptureIntentRuntime+LongRunning.swift`. Provide Context never uses either
/// wrapper and stays a normal AppIntent.
///
/// The override is a shadowing method on the concrete intent type, so the call
/// in `perform()` is identical in every app, and compiler/OS availability
/// picks the runtime.
protocol CaptureIntentRuntime: AppIntent {}

extension CaptureIntentRuntime {
    func withCaptureRuntime<T>(
        reporter: IntentProgressReporter,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await operation()
    }

    /// How long a save press inside this intent may wait for its classified
    /// outcome. Short by default: the save is one leg of a ~30 s total budget it
    /// must not consume (see `IntentSaveTimeout`).
    var captureSaveTimeout: TimeInterval { IntentSaveTimeout.standard }
}

extension SaveIntent: CaptureIntentRuntime {}
