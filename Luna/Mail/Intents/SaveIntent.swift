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
import LunaInterop
import LunaStorage
import LunaMediaDownload
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
        /// Unpaid cross-surface save (`claudedocs/interop-purchase.md`) — the
        /// item was discarded; the dialog names the owning app and the unlock.
        case interopBlocked(message: String)

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .unsupportedApp:
                return "Luna can't save from this app."
            case .interopBlocked(let message):
                return "\(message)"
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
    }

    func perform() async throws -> some IntentResult & ReturnsValue<SaveResultEntity> & ProvidesDialog {
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
                doubleSaveActionSurface: ActionButtonIntentSupport.doubleSaveSurface)
            ScreenshotDoublePressStore.record(digest: digest, savedURLString: savedURLString)
            let media = try await ActionButtonIntentSupport.downloadMediaIfNeeded(
                for: savedURLString
            ) {
                try? await requestToContinueInForeground()
            }
            if case .friendPromptRequested = outcome {
                try? await requestToContinueInForeground()
            }
            return .result(value: SaveResultEntity(media: media), dialog: "Done.")
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
                    doubleSaveActionSurface: ActionButtonIntentSupport.doubleSaveSurface)
            } else if let platform = AppNamePlatform.platform(forAppName: app) {
                let result = try await PlatformFieldSave.save(
                    platform: platform, fields: fields,
                    doubleSaveActionSurface: ActionButtonIntentSupport.doubleSaveSurface)
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

        let savedURLString: String?
        let needsInstallOwner: InteropSurface?
        switch outcome {
        case let .completed(saved, installOwner):
            savedURLString = saved
            needsInstallOwner = installOwner
        case .friendPromptRequested(let saved):
            savedURLString = saved
            needsInstallOwner = nil
        case let .blockedByInterop(owner, _):
            // Unpaid cross-surface save: the item was discarded
            // (claudedocs/interop-purchase.md) — the dialog names the owning
            // app, the unlock, and the direct alternative.
            throw SaveError.interopBlocked(
                message: IntentIngestHelper.blockedDialogText(
                    owner: owner, currentAppName: InteropSurface.current.displayName))
        }
        if let savedURLString {
            ScreenshotDoublePressStore.record(digest: digest, savedURLString: savedURLString)
        }
        // Use the platform finder's resolved URL even when duplicate/double-save
        // handling times out and reports no saved URL. Download handoff is an
        // independent consequence of resolving downloadable media.
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
        if let needsInstallOwner {
            // Paid cross-surface save with the owning app missing: the save
            // SUCCEEDED (it's in the shared store) — mention the install.
            return .result(
                value: SaveResultEntity(media: media),
                dialog: IntentDialog(stringLiteral:
                    "Saved. Install \(needsInstallOwner.displayName) to see it there — "
                    + "it's waiting in your shared Luna library."))
        }
        return .result(value: SaveResultEntity(media: media), dialog: "Saved to Luna.")
    }

}
