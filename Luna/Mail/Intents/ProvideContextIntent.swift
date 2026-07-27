//
//  ProvideContextIntent.swift
//  Luna
//
//  App Intent definition (kept in the app target for App Intents discovery).
//  The decision core is `LunaIntents.ProvideContextDecision`; this wrapper adds
//  the supplied-URL fast path, the immediate Safari save, and foregrounding.
//

import AppIntents
import LunaIntents
import LunaModels
import LunaStorage
import Foundation

/// First step of the Action Button capture flow. Pass the current app (from
/// Get Current App); the intent decides what the Shortcut should do next and
/// returns a transient entity whose outcome is `.unhandled`, `.done`, or
/// `.requiresScreenshot`. A completed synchronous media download is attached
/// to the entity for the Shortcut to display or pass onward. Compatible complete
/// URLs supplied by the Shortcut are saved directly before app-specific fallback
/// or screenshot analysis is considered, including while Safari is current.
///
/// The background runtime and the Live-Activity permission this intent runs under
/// are per-target composition: see `CaptureIntentRuntime.swift` (universal
/// default) and `CaptureIntentRuntime+LongRunning.swift` (media apps only).
struct ProvideContextIntent: AppIntent, ForegroundContinuableIntent {
    init() {}
    static let title: LocalizedStringResource = "Provide Context"
    static let description = IntentDescription("""
        First step of the Action Button shortcut. Pass the current app (from Get \
        Current App) and optionally URLs detected on screen. Returns a structured \
        outcome telling the shortcut whether the page is done, unhandled, or \
        requires a screenshot.
        """)
    static let openAppWhenRun: Bool = false

    @Parameter(title: "App", description: "The current app, from Get Current App.")
    var app: String?

    @Parameter(
        title: "OnScreenURLs",
        description: "The output from Get On-Screen URLs. Compatible complete values may be saved directly.",
        inputConnectionBehavior: .connectToPreviousIntentResult)
    var onScreenURLs: String?

    enum ProvideContextError: Error, CustomLocalizedStringResourceConvertible {
        case noTrackedPage
        /// Foreign-kind save (`SurfaceSupport`) — the item was discarded; the
        /// dialog carries the generic unsupported-kind explanation.
        case unsupportedKind(message: String)
        /// Several different saveable links were on screen at once.
        case multipleURLs
        /// The save press left nothing in the app.
        case saveFailed
        /// The link was saved but its content couldn't be fetched.
        case contentUnavailable

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .noTrackedPage:
                return "No Safari page tracked yet. Is the Luna extension enabled?"
            case .unsupportedKind(let message):
                return "\(message)"
            case .multipleURLs:
                return "Several different links are on screen. Open the one you want and try again."
            case .saveFailed:
                return "Luna couldn't save this link."
            case .contentUnavailable:
                return "Luna saved this link but couldn't fetch the page. Try again from the app."
            }
        }

        init(saveFailure: IntentSaveVerification.Failure) {
            switch saveFailure {
            case .nothingSaved: self = .saveFailed
            case .contentUnavailable: self = .contentUnavailable
            }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<ProvideContextResultEntity> {
        LunaSetupStatusStore.shared.recordShortcutRun(
            isCentral: LunaApp.current == .luna)
        let reporter = IntentProgressReporter()
        // Which background runtime this is, and whether the system shows its own
        // progress, is decided by target membership — see `CaptureIntentRuntime`.
        let value = try await withCaptureRuntime(reporter: reporter) {
            try await self.provideContext(reporter: reporter)
        }
        return .result(value: value)
    }

    /// The intent body, independent of whether an extended runtime is wrapping
    /// it. Returns the entity; `perform` packages the result.
    private func provideContext(
        reporter: IntentProgressReporter
    ) async throws -> ProvideContextResultEntity {
        let isSafari = app.map { AppNamePlatform.isSafari(forAppName: $0) } ?? false

        // A supplied URL this app can handle takes precedence over every
        // app-based decision, including an otherwise unsupported current app —
        // and, because pre-validation says
        // the save SHOULD work, its failures are thrown rather than swallowed.
        // A link owned by a sibling app (or no usable link at all) falls through
        // in silence to the decision below. Safari uses the supplied URL too;
        // its extension-backed URL store remains the fallback when Shortcuts
        // supplies nothing usable.
        let trackedURLString = SafariURLStore.isFresh() ? SafariURLStore.lastURL : nil
        let safariURLFresh = !(trackedURLString ?? "").isEmpty
        let plan = ProvideContextOnScreenURL.plan(
            text: onScreenURLs,
            isSafari: isSafari,
            safariTrackedURLString: trackedURLString,
            isEnabled: AppIntentSettings.handleOnScreenURLs)
        if case let .save(urlString) = plan {
            return try await saveURL(urlString, reporter: reporter)
        }

        if case .divergent = plan { throw ProvideContextError.multipleURLs }

        let visionAvailable = ScreenCaptureModelSessionFactory.makeDefault().isAvailable
        let decision = ProvideContextDecision.decide(
            appName: app,
            isSafari: isSafari,
            isShortcuts: app.map { AppNamePlatform.isShortcuts(forAppName: $0) } ?? false,
            platform: app.flatMap { AppNamePlatform.platform(forAppName: $0) },
            safariURLFresh: safariURLFresh,
            // A recognized-platform save is media, so only media-handling apps
            // (Downloader, the central Luna app) proceed to a screenshot save.
            handlesMediaKind: LunaApp.current.handlesMedia,
            visionModelAvailable: visionAvailable)

        // An `.unsupported` decision ends the intent instantly, having saved
        // nothing — indistinguishable, from the outside, from a save that
        // silently did nothing. Record which inputs produced it.
        SharedDiagnosticLog.record(
            "provide context: decision=\(decision) app=\(app ?? "nil") safari=\(isSafari) "
                + "safariURLFresh=\(safariURLFresh) tracked=\(trackedURLString ?? "nil") "
                + "plan=\(plan) vision=\(visionAvailable) "
                + "handlesMedia=\(LunaApp.current.handlesMedia)",
            category: "intents")

        switch decision {
        case .unsupported:
            return ProvideContextResultEntity(outcome: .unhandled)
        case .screenshotNeeded:
            return ProvideContextResultEntity(outcome: .requiresScreenshot)
        case .saveImmediately:
            guard let urlString = SafariURLStore.lastURL, !urlString.isEmpty else {
                // Shouldn't happen (freshness implies a URL) — but never save
                // nothing silently.
                throw ProvideContextError.noTrackedPage
            }
            return try await saveURL(urlString, reporter: reporter)
        }
    }

    /// The one immediate-URL path for both Safari-extension URLs and URLs
    /// extracted from Shortcuts input. Every way it can end without content in
    /// the app throws: a foreign kind, an empty store, a `.failed` item, or a
    /// media download that never ran (thrown from the handoff). A timeout still
    /// counts as handled — the ingest task continues and persists its pending
    /// work in the background, so the item IS in the app.
    private func saveURL(
        _ urlString: String, reporter: IntentProgressReporter
    ) async throws -> ProvideContextResultEntity {
        reporter.enter(.saving)
        let outcome = await IntentIngestHelper.handleSavePress(
            urlString: urlString,
            doubleSaveActionSurface: ActionButtonIntentSupport.doubleSaveSurface,
            timeout: captureSaveTimeout)

        let savedURLString: String
        switch outcome {
        case let .friendPromptRequested(savedURL):
            try? await requestToContinueInForeground()
            savedURLString = savedURL
        case let .completed(savedURL):
            // Nil means only that the save race expired. The ingest task
            // continues, exactly as it does for a Safari-extension URL.
            savedURLString = savedURL ?? urlString
        case let .unsupportedKind(owner):
            throw ProvideContextError.unsupportedKind(
                message: IntentIngestHelper.unsupportedDialogText(owner: owner))
        case let .saveFailed(failure):
            throw ProvideContextError(saveFailure: failure)
        }

        reporter.enter(.downloading)
        ActionButtonIntentSupport.byteProgress = { received, expected in
            reporter.setExpectedBytes(expected)
            reporter.setReceivedBytes(received)
        }
        defer { ActionButtonIntentSupport.byteProgress = nil }
        let media = try await ActionButtonIntentSupport.downloadMediaIfNeeded(
            for: savedURLString
        ) {
            try? await requestToContinueInForeground()
        }
        reporter.enter(.finishing)
        return ProvideContextResultEntity(outcome: .done, media: media)
    }
}

/// Shared plumbing for the two Action Button intents (Provide Context + Save).
enum ActionButtonIntentSupport {

    /// Media-kind download handoff, installed by `MediaIntentHandoff.install()`
    /// (media apps only — Downloader + the central Luna app). Nil in
    /// article/product-only apps ⇒ the intents return no media, matching the
    /// gate that only media-handling apps hand off.
    static var mediaHandoff: ((String, () async -> Void) async throws -> IntentFile?)?

    /// Set for the duration of an awaited media handoff so the transfer's real
    /// `(received, expected)` byte counts reach the running intent's progress
    /// reporter. A plain closure rather than a parameter because the handoff seam
    /// is installed per-target and must stay kind-agnostic.
    static var byteProgress: ((Int64, Int64?) -> Void)?

    /// One media handoff shared by ProvideContext's completed Safari fast path
    /// and SaveIntent's screenshot/search path. `foreground` is invoked only
    /// when a first read/write Photos authorization prompt needs a visible host.
    static func downloadMediaIfNeeded(
        for urlString: String,
        foreground: () async -> Void
    ) async throws -> IntentFile? {
        guard let mediaHandoff else { return nil }
        return try await mediaHandoff(urlString, foreground)
    }

    /// The double-save action (send to Kindle / friend on a repeat press within
    /// 7 s) is armed only for the Reader app's Action Button saves — every other
    /// surface and save path keeps the plain save behavior.
    static var doubleSaveSurface: String? {
        guard LunaApp.current == .reader else { return nil }
        return LunaApp.current.storageIdentifier
    }
}
