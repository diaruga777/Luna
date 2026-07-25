//
//  SaveIntent.swift
//  Luna
//
//  App Intent definition (kept in the app target for App Intents discovery).
//  The pieces are all in LunaIntents: the vision seam
//  (`ScreenCaptureModelSessionFactory`), digest double-press detection
//  (`ScreenshotDigest`/`ScreenshotDoublePress`), response parsing
//  (`SaveResponseParsing`), and the save routing (`PlatformFieldSave` /
//  `SafariPageSave`).
//

import AppIntents
import LunaIntents
import LunaModels
import LunaStorage
import Foundation

/// Second step of the Action Button capture flow: given the current app and a
/// screenshot of it, runs the app-specific screen-extraction prompt through the
/// in-process FoundationModels vision session (Private Cloud Compute when
/// available, else the on-device model), parses the " ; "-joined response, and
/// saves the matching post/page through the action-button save path
/// (double-save preserved). A near-immediate repeat of the same screenshot
/// skips the model and re-runs the previous save so the configured double-save
/// action fires. Returns a transient entity containing the downloaded image or
/// video when synchronous intent media is enabled; throws descriptive errors.
/// The background runtime and the Live-Activity permission this intent runs under
/// are per-target composition: see `CaptureIntentRuntime.swift` (universal
/// default) and `CaptureIntentRuntime+LongRunning.swift` (media apps only).
struct SaveIntent: AppIntent, ForegroundContinuableIntent {
    init() {}
    static let title: LocalizedStringResource = "Save"
    static let description = IntentDescription("""
        Second step of the Action Button shortcut. Pass the current app (from \
        Get Current App) and a screenshot of it; Luna reads the screen with an \
        on-device/Private Cloud Compute model and saves the matching post or \
        page.
        """)
    static let openAppWhenRun: Bool = false

    @Parameter(title: "App", description: "The current app, from Get Current App.")
    var app: String

    @Parameter(
        title: "Screenshot",
        description: "A screenshot of the current app's screen.",
        supportedContentTypes: [.image])
    var screenshot: IntentFile

    enum SaveError: Error, CustomLocalizedStringResourceConvertible {
        case unsupportedApp
        case modelUnavailable
        case networkUnavailable
        case quotaLimitReached
        case serviceUnavailable
        case nothingIdentifiable
        case notFound
        /// Foreign-kind save (`SurfaceSupport`) — the item was discarded; the
        /// dialog carries the generic unsupported-kind explanation.
        case unsupportedKind(message: String)
        /// The screen read identified something, but the save left nothing in
        /// the app.
        case saveFailed
        /// Saved, but the page/post content couldn't be fetched.
        case contentUnavailable

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .unsupportedApp:
                return "Luna can't save from this app."
            case .unsupportedKind(let message):
                return "\(message)"
            case .saveFailed:
                return "Luna found this on screen but couldn't save it."
            case .contentUnavailable:
                return "Luna saved this but couldn't fetch its content. Try again from the app."
            case .modelUnavailable:
                // ITMS-90626: never mention Apple/Siri in intent-visible strings.
                return "Screen analysis isn't available on this device."
            case .networkUnavailable:
                return "Screen analysis needs a network connection. Try again when you're back online."
            case .quotaLimitReached:
                return "You've hit the screen-analysis limit for now. Try again later."
            case .serviceUnavailable:
                return "Screen analysis is temporarily unavailable. Try again in a moment."
            case .nothingIdentifiable:
                return "Couldn't identify anything to save on this screen."
            case .notFound:
                return "Couldn't find a matching post or page to save."
            }
        }

        init(modelError: ScreenCaptureModelError) {
            switch modelError {
            case .modelUnavailable: self = .modelUnavailable
            case .networkFailure: self = .networkUnavailable
            case .quotaLimitReached: self = .quotaLimitReached
            case .serviceUnavailable, .other: self = .serviceUnavailable
            }
        }

        init(saveFailure: IntentSaveVerification.Failure) {
            switch saveFailure {
            case .nothingSaved: self = .saveFailed
            case .contentUnavailable: self = .contentUnavailable
            }
        }
    }

    /// The one place a save outcome becomes either the URL to hand onward or a
    /// thrown error. A screen read that identified a post/page has already
    /// passed this intent's pre-validation, so every non-success outcome is
    /// reported — the extraction worked and the SAVE is what failed.
    private func savedURLString(
        from outcome: IntentIngestHelper.ActionButtonSaveOutcome
    ) throws -> String? {
        switch outcome {
        case let .completed(saved):
            return saved
        case let .friendPromptRequested(saved):
            return saved
        case let .unsupportedKind(owner):
            // Foreign-kind save: the item was discarded — the dialog carries
            // the generic unsupported-kind explanation.
            throw SaveError.unsupportedKind(
                message: IntentIngestHelper.unsupportedDialogText(owner: owner))
        case let .saveFailed(failure):
            throw SaveError(saveFailure: failure)
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<SaveResultEntity> & ProvidesDialog {
        LunaSetupStatusStore.shared.recordShortcutRun(
            isCentral: AppSurfaceConfig.current == .all)
        let reporter = IntentProgressReporter()
        // Which background runtime this is, and whether the system shows its own
        // progress, is decided by target membership — see `CaptureIntentRuntime`.
        let saved = try await withCaptureRuntime(reporter: reporter) {
            try await self.save(reporter: reporter)
        }
        return .result(value: saved.value, dialog: saved.dialog)
    }

    /// The intent body, independent of whether an extended runtime is wrapping
    /// it. Returns the value + dialog; `perform` packages the result.
    private func save(
        reporter: IntentProgressReporter
    ) async throws -> (value: SaveResultEntity, dialog: IntentDialog) {
        reporter.enter(.saving)
        let imageData = screenshot.data
        guard let digest = ScreenshotDigest.digest(forImageData: imageData) else {
            // Undecodable image data — the model couldn't read it either.
            throw SaveError.nothingIdentifiable
        }

        // Double-press: a near-immediate repeat of the same screenshot skips
        // the model and re-runs the previous save, so the configured
        // double-save action (Kindle / friend / prompt) fires.
        if case .treatAsDoublePress(let savedURLString) = ScreenshotDoublePress.decide(
            newDigest: digest, previous: ScreenshotDoublePressStore.last()
        ) {
            let outcome = await IntentIngestHelper.handleSavePress(
                urlString: savedURLString,
                doubleSaveActionSurface: ActionButtonIntentSupport.doubleSaveSurface,
                timeout: captureSaveTimeout)
            // Verify the re-press before recording it or downloading anything:
            // re-running a save whose item is gone or failed is a failure too.
            _ = try self.savedURLString(from: outcome)
            ScreenshotDoublePressStore.record(digest: digest, savedURLString: savedURLString)
            reporter.enter(.downloading)
            let media = try await ActionButtonIntentSupport.downloadMediaIfNeeded(
                for: savedURLString
            ) {
                try? await requestToContinueInForeground()
            }
            reporter.enter(.finishing)
            if case .friendPromptRequested = outcome {
                try? await requestToContinueInForeground()
            }
            return (SaveResultEntity(media: media), "Done.")
        }

        let isSafari = AppNamePlatform.isSafari(forAppName: app)
        let prompt: String
        if isSafari {
            prompt = AppNamePlatform.safariScreenPrompt
        } else if let screenPrompt = AppNamePlatform.screenPrompt(forAppName: app) {
            prompt = screenPrompt
        } else {
            throw SaveError.unsupportedApp
        }

        let session = ScreenCaptureModelSessionFactory.makeDefault()
        guard session.isAvailable else { throw SaveError.modelUnavailable }
        let response: String
        do {
            response = try await session.extract(prompt: prompt, imageData: imageData)
        } catch let error as ScreenCaptureModelError {
            throw SaveError(modelError: error)
        }

        let fields = SaveResponseParsing.parseFields(from: response)
        guard !fields.isEmpty else { throw SaveError.nothingIdentifiable }

        let outcome: IntentIngestHelper.ActionButtonSaveOutcome
        var resolvedPlatformURLString: String?
        do {
            if isSafari {
                outcome = try await SafariPageSave.save(
                    title: fields[0],
                    site: fields.count > 1 ? fields[1] : nil,
                    doubleSaveActionSurface: ActionButtonIntentSupport.doubleSaveSurface,
                    saveTimeout: captureSaveTimeout)
            } else if let platform = AppNamePlatform.platform(forAppName: app) {
                let result = try await PlatformFieldSave.save(
                    platform: platform, fields: fields,
                    doubleSaveActionSurface: ActionButtonIntentSupport.doubleSaveSurface,
                    saveTimeout: captureSaveTimeout)
                outcome = result.outcome
                resolvedPlatformURLString = result.resolvedURLString
            } else {
                throw SaveError.unsupportedApp
            }
        } catch let error as PlatformFieldSave.SaveError {
            switch error {
            case .notFound: throw SaveError.notFound
            case .missingValues: throw SaveError.nothingIdentifiable
            }
        } catch let error as SafariPageSave.SaveError {
            switch error {
            case .notFound: throw SaveError.notFound
            }
        }

        let savedURLString = try self.savedURLString(from: outcome)
        if let savedURLString {
            ScreenshotDoublePressStore.record(digest: digest, savedURLString: savedURLString)
        }
        // Use the platform finder's resolved URL even when duplicate/double-save
        // handling times out and reports no saved URL. Download handoff is an
        // independent consequence of resolving downloadable media.
        reporter.enter(.downloading)
        let media: IntentFile?
        if let downloadURLString = resolvedPlatformURLString ?? savedURLString {
            media = try await ActionButtonIntentSupport.downloadMediaIfNeeded(
                for: downloadURLString
            ) {
                try? await requestToContinueInForeground()
            }
        } else {
            media = nil
        }
        if case .friendPromptRequested = outcome {
            // Foreground Luna so the friend selector (pending prompt already
            // recorded) can appear.
            try? await requestToContinueInForeground()
        }
        reporter.enter(.finishing)
        return (SaveResultEntity(media: media), "Saved to Luna.")
    }

}
