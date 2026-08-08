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
import UniformTypeIdentifiers

/// First step of the Action Button capture flow. Pass the current app (from
/// Get Current App); the intent decides what the Shortcut should do next and
/// returns a transient entity whose outcome is `.unhandled`, `.done`,
/// `.screenshot`, or `.download`. It deliberately remains a normal AppIntent:
/// fast saves finish here, while media transfers and work approaching the normal
/// runtime limit hand a resumable opaque checkpoint to the LongRunning SaveIntent.
struct ProvideContextIntent: AppIntent, ForegroundContinuableIntent {
    init() {}
    static let title: LocalizedStringResource = "Intents_provideContext_title_Luna"
    static let description = IntentDescription("Intents_provideContext_description_Luna")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Intents_provideContext_currentAppParam_title_Luna",
               description: "Intents_provideContext_currentAppParam_description_Luna")
    var currentApp: String?

    @Parameter(
        title: "Intents_provideContext_onScreenURLsParam_title_Luna",
        description: "Intents_provideContext_onScreenURLsParam_description_Luna",
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
                return L10n.resource("Intents_provideContext_noTrackedPageError")
            case .unsupportedKind(let message):
                return "\(message)"
            case .multipleURLs:
                return L10n.resource("Intents_provideContext_multipleURLsError")
            case .saveFailed:
                return L10n.resource("Intents_provideContext_saveFailedError")
            case .contentUnavailable:
                return L10n.resource("Intents_provideContext_contentUnavailableError")
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
        let attemptDate = Date()
        LunaSetupStatusStore.shared.recordShortcutRun(for: .current)
        let value = try await provideContext(attemptDate: attemptDate)
        return .result(value: value)
    }

    private func provideContext(attemptDate: Date) async throws -> ProvideContextResultEntity {
        // A sibling Luna app owns the screen: nothing here is ours to save, and
        // that verdict outranks even a supplied on-screen URL (a link showing
        // inside another Luna app is already saved, in the app that owns its
        // kind). Reported as plainly unhandled so the Shortcut just stops.
        if AppNamePlatform.isSiblingLunaApp(currentApp) {
            SharedDiagnosticLog.record(
                "provide context: ignored — sibling Luna app frontmost "
                    + "(app=\(currentApp ?? "nil"))",
                category: "intents")
            return ProvideContextResultEntity(outcome: .unhandled)
        }

        let isSafari = currentApp.map { AppNamePlatform.isSafari(forAppName: $0) } ?? false

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
            return try await saveURL(urlString, attemptDate: attemptDate)
        }

        if case .divergent = plan { throw ProvideContextError.multipleURLs }

        let visionAvailable = ScreenCaptureModelSessionFactory.makeDefault().isAvailable
        // Opportunistic on purpose: the tracked URL lives in the one shared App
        // Group, so ANY installed Luna app's extension having run is evidence
        // that this app should have had a page URL to read.
        let safariExtensionHasRun = LunaSetupStatusStore.shared.anySafariExtensionHasRun
        let decision = ProvideContextDecision.decide(
            appName: currentApp,
            isSafari: isSafari,
            isShortcuts: currentApp.map { AppNamePlatform.isShortcuts(forAppName: $0) } ?? false,
            platform: currentApp.flatMap { AppNamePlatform.platform(forAppName: $0) },
            safariURLFresh: safariURLFresh,
            safariExtensionHasRun: safariExtensionHasRun,
            // A recognized-platform save is media, so only media-handling apps
            // (Downloader, the central Luna app) proceed to a screenshot save.
            handlesMediaKind: LunaApp.current.handlesMedia,
            visionModelAvailable: visionAvailable)

        // An `.unsupported` decision ends the intent instantly, having saved
        // nothing — indistinguishable, from the outside, from a save that
        // silently did nothing. Record which inputs produced it.
        SharedDiagnosticLog.record(
            "provide context: decision=\(decision) app=\(currentApp ?? "nil") safari=\(isSafari) "
                + "safariURLFresh=\(safariURLFresh) tracked=\(trackedURLString ?? "nil") "
                + "safariExtensionHasRun=\(safariExtensionHasRun) "
                + "plan=\(plan) vision=\(visionAvailable) "
                + "handlesMedia=\(LunaApp.current.handlesMedia)",
            category: "intents")

        switch decision {
        case .unsupported:
            return ProvideContextResultEntity(outcome: .unhandled)
        case .noSafariURL:
            throw ProvideContextError.noTrackedPage
        case .screenshotNeeded:
            let metadata = CaptureIntentMetadata(
                phase: .screenshot, currentApp: currentApp).opaqueString
            return ProvideContextResultEntity(
                outcome: .screenshot, metadata: metadata)
        case .saveImmediately:
            guard let urlString = SafariURLStore.lastURL, !urlString.isEmpty else {
                // Shouldn't happen (freshness implies a URL) — but never save
                // nothing silently.
                throw ProvideContextError.noTrackedPage
            }
            return try await saveURL(urlString, attemptDate: attemptDate)
        }
    }

    /// The one immediate-URL path for both Safari-extension URLs and URLs
    /// extracted from Shortcuts input. Every way it can end without content in
    /// the app throws: a foreign kind, an empty store, a `.failed` item, or a
    /// media download that never ran (thrown from the handoff). The complete
    /// preparation path has one 20 s deadline. If it expires, the losing task is
    /// cancelled and the durable prepared save is returned for SaveIntent to
    /// resume without another reservation or duplicate work.
    private func saveURL(
        _ urlString: String, attemptDate: Date
    ) async throws -> ProvideContextResultEntity {
        guard let prepared = IntentIngestHelper.prepareSavePress(
            urlString: urlString,
            doubleSaveActionSurface: ActionButtonIntentSupport.doubleSaveSurface,
            attemptDate: attemptDate)
        else { throw ProvideContextError.saveFailed }

        // A non-trivial double-save action is already decided atomically. Run it
        // exactly once under SaveIntent rather than beginning a send/export here
        // and risking duplication if the normal-runtime deadline wins the race.
        if prepared.isDoubleSave, case .ignore = prepared.action {
            // The configured action is intentionally inert; verification below
            // is immediate and completes in the fast path.
        } else if prepared.isDoubleSave {
            return continuationResult(
                phase: .save, urlString: prepared.urlString,
                prepared: prepared)
        }

        let deadline = attemptDate.addingTimeInterval(IntentSaveTimeout.provideContext)
        let outcome: IntentIngestHelper.ActionButtonSaveOutcome
        do {
            outcome = try await CaptureIntentFastPath.run(
                timeout: deadline.timeIntervalSinceNow) {
                    await IntentIngestHelper.performPreparedSavePress(prepared)
                }
        } catch CaptureIntentFastPathError.timedOut {
            SharedDiagnosticLog.record(
                "provide context: 20 s fast path expired during save; handing off \(prepared.urlString)",
                category: "intents")
            return continuationResult(
                phase: .save, urlString: prepared.urlString,
                prepared: prepared)
        }

        let savedURLString: String
        // A double save whose action is "View immediately": the article document IS
        // this run's media, so it replaces the media download below (an article
        // has none anyway).
        var exportedFile: IntentFile?
        switch outcome {
        case let .friendPromptRequested(savedURL):
            try? await requestToContinueInForeground()
            savedURLString = savedURL
        case let .exportRequested(item, format):
            savedURLString = item.urlString
            exportedFile = await ActionButtonIntentSupport.exportFile(
                for: item, format: format)
        case let .completed(savedURL):
            savedURLString = savedURL ?? urlString
        case let .unsupportedKind(owner):
            throw ProvideContextError.unsupportedKind(
                message: IntentIngestHelper.unsupportedDialogText(owner: owner))
        case let .saveFailed(failure):
            throw ProvideContextError(saveFailure: failure)
        }

        if let exportedFile {
            IntentIngestHelper.finishSaveAttempt(urlString: savedURLString)
            return ProvideContextResultEntity(outcome: .done, media: exportedFile)
        }

        // A product save's OWN media is the comparison summary. The fan-out
        // itself already ran inside the save above (it is part of ingesting a
        // product), so what is left here is the document: refreshing any seller
        // whose price is over a day old, fetching favicons, drawing the graph.
        // That is minutes of network in the worst case, which is precisely what
        // the checkpoint is for — the save is durable either way.
        if ActionButtonIntentSupport.handlesProductComparison {
            do {
                let file = try await CaptureIntentFastPath.run(
                    timeout: deadline.timeIntervalSinceNow) {
                        await ActionButtonIntentSupport.comparisonFile(for: savedURLString)
                    }
                if let file {
                    IntentIngestHelper.finishSaveAttempt(urlString: savedURLString)
                    return ProvideContextResultEntity(outcome: .done, media: file)
                }
            } catch CaptureIntentFastPathError.timedOut {
                SharedDiagnosticLog.record(
                    "provide context: 20 s fast path expired building the seller comparison; "
                        + "handing off \(savedURLString)",
                    category: "intents")
                IntentIngestHelper.finishSaveAttempt(urlString: savedURLString)
                return continuationResult(
                    phase: .comparison, urlString: savedURLString, prepared: prepared)
            }
        }

        let preparation: ActionButtonIntentSupport.MediaPreparation
        do {
            preparation = try await CaptureIntentFastPath.run(
                timeout: deadline.timeIntervalSinceNow) {
                    try await ActionButtonIntentSupport.prepareMediaIfNeeded(
                        for: savedURLString)
                }
        } catch CaptureIntentFastPathError.timedOut {
            SharedDiagnosticLog.record(
                "provide context: 20 s fast path expired during media preflight; handing off \(savedURLString)",
                category: "intents")
            IntentIngestHelper.finishSaveAttempt(urlString: savedURLString)
            return continuationResult(
                phase: .download, urlString: savedURLString,
                prepared: prepared)
        }

        IntentIngestHelper.finishSaveAttempt(urlString: savedURLString)
        switch preparation {
        case .none:
            return ProvideContextResultEntity(outcome: .done)
        case .completed(let media):
            return ProvideContextResultEntity(outcome: .done, media: media)
        case .download(let media):
            return continuationResult(
                phase: .download, urlString: savedURLString,
                prepared: prepared, media: media)
        }
    }

    private func continuationResult(
        phase: CaptureIntentMetadata.Phase,
        urlString: String,
        prepared: IntentIngestHelper.PreparedSavePress,
        media: IntentMediaCheckpoint? = nil
    ) -> ProvideContextResultEntity {
        let metadata = CaptureIntentMetadata(
            phase: phase,
            currentApp: currentApp,
            resolvedURLString: urlString,
            isDoubleSave: prepared.isDoubleSave,
            preparedSave: prepared,
            media: media).opaqueString
        return ProvideContextResultEntity(
            outcome: .download, metadata: metadata)
    }
}

/// Shared plumbing for the two Action Button intents (Provide Context + Save).
enum ActionButtonIntentSupport {

    enum MediaPreparation {
        /// The URL is not downloadable media in this app.
        case none
        /// Media already exists locally, so no long-running work is required.
        case completed(IntentFile)
        /// SaveIntent must perform the actual transfer. The checkpoint is nil
        /// when resolution/preflight could not finish and Save should retry it.
        case download(IntentMediaCheckpoint?)
    }

    /// Media-kind download handoff, installed by `MediaIntentHandoff.install()`
    /// (media apps only — Downloader + the central Luna app). Nil in
    /// article/product-only apps ⇒ the intents return no media, matching the
    /// gate that only media-handling apps hand off.
    static var mediaPreparation: ((String) async throws -> MediaPreparation)?
    static var mediaHandoff:
        ((String, IntentMediaCheckpoint?, () async -> Void) async throws -> IntentFile?)?

    /// Set for the duration of an awaited media handoff so the transfer's real
    /// `(received, expected)` byte counts reach the running intent's progress
    /// reporter. A plain closure rather than a parameter because the handoff seam
    /// is installed per-target and must stay kind-agnostic.
    static var byteProgress: ((Int64, Int64?) -> Void)?

    /// SaveIntent's media handoff for prepared and from-scratch paths.
    /// `foreground` is invoked only
    /// when a first read/write Photos authorization prompt needs a visible host.
    static func downloadMediaIfNeeded(
        for urlString: String,
        checkpoint: IntentMediaCheckpoint? = nil,
        foreground: () async -> Void
    ) async throws -> IntentFile? {
        guard let mediaHandoff else { return nil }
        return try await mediaHandoff(urlString, checkpoint, foreground)
    }

    /// Resolves redirects/assets, validates storage, and obtains the expected
    /// byte count without starting a transfer. Only media targets install this
    /// seam; other apps complete with `.none` immediately.
    static func prepareMediaIfNeeded(
        for urlString: String
    ) async throws -> MediaPreparation {
        guard let mediaPreparation else { return .none }
        return try await mediaPreparation(urlString)
    }

    /// The product-kind comparison summary, installed by
    /// `ProductIntentHandoff.install()` (product apps only — Price Tracker + the
    /// central Luna app). Nil elsewhere, so an article/media-only app's intents
    /// never look for one.
    ///
    /// Given a just-saved URL it answers with the self-contained HTML document
    /// for the tracker that URL belongs to, refreshing any seller whose price is
    /// over a day old first — and nil when the URL is not a tracked product, or
    /// is a tracker with a single store (one price is not a comparison).
    static var productComparisonDocument: ((String) async -> URL?)?

    /// Whether this app can produce a comparison document at all. Read BEFORE
    /// spending any deadline on one.
    static var handlesProductComparison: Bool { productComparisonDocument != nil }

    /// The comparison document as returnable intent media. Nil is the ordinary
    /// answer for every non-product save.
    static func comparisonFile(for urlString: String) async -> IntentFile? {
        guard let fileURL = await productComparisonDocument?(urlString) else { return nil }
        return IntentFile(
            fileURL: fileURL,
            filename: fileURL.lastPathComponent,
            type: UTType(filenameExtension: fileURL.pathExtension) ?? .html)
    }

    /// Article-document export for a "View immediately" double save. Installed
    /// by the two `KindWiring` variants that
    /// link LunaSend (Luna + Reader); nil elsewhere, matching
    /// `doubleSaveSurface`. Returns the temp file's URL.
    static var articleExporter: ((ReadingListItem, ArticleExportFormat) async -> URL?)?

    /// Builds the double save's article file and wraps it as the intent's
    /// returned media. Nil when the seam isn't installed or the article has no
    /// content to export — a double save must never fail the save that
    /// preceded it.
    static func exportFile(
        for item: ReadingListItem, format: ArticleExportFormat
    ) async -> IntentFile? {
        guard let fileURL = await articleExporter?(item, format) else { return nil }
        return IntentFile(
            fileURL: fileURL,
            filename: fileURL.lastPathComponent,
            type: UTType(filenameExtension: fileURL.pathExtension) ?? .data)
    }

    /// The double-save action (Settings → Shortcut & Safari) is armed only for
    /// the Action Button saves of the two apps that hold articles AND can build
    /// article files — the central Luna app and Reader. Every other surface and
    /// save path keeps the plain save behavior.
    static var doubleSaveSurface: String? {
        switch LunaApp.current {
        case .luna, .reader: return LunaApp.current.storageIdentifier
        case .downloader, .priceTracker: return nil
        }
    }
}
