//
//  CaptureIntentRuntime.swift
//  Luna
//
//  Which background runtime the capture intents run under — the UNIVERSAL
//  default. Per-target composition, like every other kind-specific seam in this
//  shell: `CaptureIntentRuntime+LongRunning.swift` overrides this for the
//  media-handling apps and is excluded from the others (membership exceptions in
//  the synchronized group — never `#if canImport`, which leaks across targets).
//

import AppIntents
import Foundation

/// The default runtime: run the body inline under the ordinary background budget
/// (~30 s, Apple's documented figure for an app intent).
///
/// That is enough for **Luna Reader** and **Luna Price Tracker**: their captures
/// end at the save — an article fetch or a price fetch, both bounded by the
/// ingest pipeline's own timeout and the intent layer's 12 s race. Only the
/// media-handling apps (**Luna Downloader** and the central **Luna**) can blow
/// through 30 s, because their handoff adds a preflight HEAD and an awaited
/// transfer on top of the save; those two override this with
/// `LongRunningIntent` (see `CaptureIntentRuntime+LongRunning.swift`).
///
/// The override is a shadowing method on the concrete intent type, so the call in
/// `perform()` is identical in every app and the choice is made at compile time
/// by target membership.
protocol CaptureIntentRuntime: AppIntent {}

extension CaptureIntentRuntime {
    func withCaptureRuntime<T>(
        reporter: IntentProgressReporter,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await operation()
    }
}

extension ProvideContextIntent: CaptureIntentRuntime {}
extension SaveIntent: CaptureIntentRuntime {}
