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

/// Long-running second step of the Action Button capture flow. It either
/// resumes the opaque checkpoint returned by Provide Context, or, given a
/// screenshot, runs the app-specific screen-extraction prompt through the
/// in-process FoundationModels vision session (Private Cloud Compute when
/// available, else the on-device model), parses the " ; "-joined response, and
/// saves the matching post or page through the action-button save path, with
/// double-save preserved. A near-immediate repeat of the same screenshot
/// skips the model and re-runs the previous save, so the configured
/// double-save action fires. Returns a transient entity containing the
/// downloaded image or video when synchronous intent media is enabled;
/// throws descriptive errors otherwise. See `CaptureIntentRuntime*.swift`:
/// Save alone adopts the iOS 27 extended runtime in every app, while
/// stable-SDK builds keep the ordinary-runtime fallback.
struct SaveIntent: AppIntent, ForegroundContinuableIntent {
    init() {}
    static let title: LocalizedStringResource = "Intents_save_title_Luna"
    static let description = IntentDescription("Intents_save_description_Luna")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Intents_save_currentAppParam_title_Luna",
               description: "Intents_save_currentAppParam_description_Luna")
    var currentApp: String

    @Parameter(
        title: "Intents_save_screenshotParam_title_Luna",
        description: "Intents_save_screenshotParam_description_Luna",
        supportedContentTypes: [.image])
    var screenshot: IntentFile?

    @Parameter(
        title: "Intents_save_metadataParam_title_Luna",
        description: "Intents_save_metadataParam_description_Luna")
    var metadata: String?

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
                return L10n.resource("Intents_save_unsupportedAppError")
            case .unsupportedKind(let message):
                return "\(message)"
            case .saveFailed:
                return L10n.resource("Intents_save_saveFailedError")
            case .contentUnavailable:
                return L10n.resource("Intents_save_contentUnavailableError")
            case .modelUnavailable:
                // ITMS-90626: never mention Apple/Siri in intent-visible strings.
                return L10n.resource("Intents_save_modelUnavailableError")
            case .networkUnavailable:
                return L10n.resource("Intents_save_networkUnavailableError")
            case .quotaLimitReached:
                return L10n.resource("Intents_save_quotaLimitReachedError")
            case .serviceUnavailable:
                return L10n.resource("Intents_save_serviceUnavailableError")
            case .nothingIdentifiable:
                return L10n.resource("Intents_save_nothingIdentifiableError")
            case .notFound:
                return L10n.resource("Intents_save_notFoundError")
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

    /// The one place a save outcome becomes either the URL to hand onward or
    /// a thrown error. A screen read that identified a post or page has
    /// already passed this intent's pre-validation, so every non-success
    /// outcome is reported: the extraction worked, and the save is what
    /// failed.
    private func savedURLString(
        from outcome: IntentIngestHelper.ActionButtonSaveOutcome
    ) throws -> String? {
        switch outcome {
        case let .completed(saved):
            return saved
        case let .friendPromptRequested(saved):
            return saved
        case let .exportRequested(item, _):
            return item.urlString
        case let .unsupportedKind(owner):
            // Foreign-kind save: the item was discarded — the dialog carries
            // the generic unsupported-kind explanation.
            throw SaveError.unsupportedKind(
                message: IntentIngestHelper.unsupportedDialogText(owner: owner))
        case let .saveFailed(failure):
            throw SaveError(saveFailure: failure)
        }
    }

    /// The article document a double save configured as "View immediately"
    /// should return. Nil for every other outcome, and for an article with
    /// nothing to export, since a double save must never fail the save that
    /// preceded it. When non-nil, it is this run's media, replacing the media
    /// download — an article has none.
    private static func exportedFile(
        from outcome: IntentIngestHelper.ActionButtonSaveOutcome
    ) async -> IntentFile? {
        guard case let .exportRequested(item, format) = outcome else { return nil }
        return await ActionButtonIntentSupport.exportFile(for: item, format: format)
    }

    func perform() async throws -> some IntentResult & ReturnsValue<SaveResultEntity> & ProvidesDialog {
        // Captured before setup, progress, and runtime work. This timestamp
        // follows the run to the atomic store reservation, so a second
        // invocation does not have to wait for the first invocation to tear
        // down.
        let attemptDate = Date()
        await MainActor.run { AppLaunchServices.shared.ensureReady() }
        LunaSetupStatusStore.shared.recordShortcutRun(for: .current)
        let reporter = IntentProgressReporter()
        // Compiler/OS availability decides whether Save gets the iOS 27
        // extended runtime and its system progress UI.
        let saved = try await withCaptureRuntime(reporter: reporter) {
            try await self.save(reporter: reporter, attemptDate: attemptDate)
        }
        return .result(value: saved.value, dialog: saved.dialog)
    }

    /// The intent body, independent of whether an extended runtime is wrapping
    /// it. Returns the value + dialog; `perform` packages the result.
    private func save(
        reporter: IntentProgressReporter, attemptDate: Date
    ) async throws -> (value: SaveResultEntity, dialog: IntentDialog) {
        // A Luna app owns the screen. This has to come before every input path,
        // including the double-press path below, which would otherwise re-run
        // the previous save without consulting the current app.
        if AppNamePlatform.isLunaApp(currentApp) {
            SharedDiagnosticLog.record(
                "save: ignored — Luna app frontmost (app=\(currentApp))",
                category: "intents")
            return (SaveResultEntity(), "Nothing to save from a Luna app.")
        }

        if let resumed = try await resumeFromMetadataIfPossible(reporter: reporter) {
            return resumed
        }

        reporter.enter(.saving)
        guard let screenshot else { throw SaveError.nothingIdentifiable }
        let imageData = screenshot.data
        guard let digest = ScreenshotDigest.digest(forImageData: imageData) else {
            // Undecodable image data — the model couldn't read it either.
            throw SaveError.nothingIdentifiable
        }

        // Two-phase durable state. As soon as a URL is known, commit the
        // screenshot/URL/start timestamp before ingest or export. At every exit,
        // extend both screenshot and saves markers to completion time.
        var timingURLString: String?
        let commitResolvedURL: (String) -> Void = { urlString in
            timingURLString = urlString
            ScreenshotDoublePressStore.record(
                digest: digest, savedURLString: urlString, now: attemptDate)
        }
        defer {
            if let urlString = timingURLString {
                let completedAt = Date()
                ScreenshotDoublePressStore.finish(
                    digest: digest, savedURLString: urlString, at: completedAt)
                IntentIngestHelper.finishSaveAttempt(
                    urlString: urlString, at: completedAt)
            }
        }

        // Double-press: a near-immediate repeat of the same screenshot skips
        // the model and re-runs the previous save, so the configured
        // double-save action (Kindle / friend / prompt) fires.
        if case .treatAsDoublePress(let savedURLString) = ScreenshotDoublePress.decide(
            newDigest: digest, previous: ScreenshotDoublePressStore.last(), now: attemptDate
        ) {
            // This is deliberately before handleSavePress: a third overlapping
            // invocation must see this run even while its action is still busy.
            commitResolvedURL(savedURLString)
            let outcome = await IntentIngestHelper.handleSavePress(
                urlString: savedURLString,
                doubleSaveActionSurface: ActionButtonIntentSupport.doubleSaveSurface,
                timeout: captureSaveTimeout, attemptDate: attemptDate)
            // Verify the re-press before recording it or downloading anything:
            // re-running a save whose item is gone or failed is a failure too.
            _ = try self.savedURLString(from: outcome)
            if let exported = await Self.exportedFile(from: outcome) {
                reporter.enter(.finishing)
                return (SaveResultEntity(media: exported), "Done.")
            }
            let media = try await downloadMedia(
                for: savedURLString, reporter: reporter)
            reporter.enter(.finishing)
            if case .friendPromptRequested = outcome {
                try? await requestToContinueInForeground()
            }
            return (SaveResultEntity(media: media), "Done.")
        }

        let isSafari = AppNamePlatform.isSafari(forAppName: currentApp)
        let prompt: String
        if isSafari {
            prompt = AppNamePlatform.safariScreenPrompt
        } else if let screenPrompt = AppNamePlatform.screenPrompt(forAppName: currentApp) {
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
                    saveTimeout: captureSaveTimeout, attemptDate: attemptDate,
                    onResolvedURL: commitResolvedURL)
            } else if let platform = AppNamePlatform.platform(forAppName: currentApp) {
                let result = try await PlatformFieldSave.save(
                    platform: platform, fields: fields,
                    doubleSaveActionSurface: ActionButtonIntentSupport.doubleSaveSurface,
                    saveTimeout: captureSaveTimeout, attemptDate: attemptDate,
                    onResolvedURL: commitResolvedURL)
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
            // Ingest may unwrap/repoint the URL. Make that durable while keeping
            // the original start timestamp; defer extends it to completion.
            commitResolvedURL(savedURLString)
        }
        if let exported = await Self.exportedFile(from: outcome) {
            reporter.enter(.finishing)
            return (SaveResultEntity(media: exported), "Saved to Luna.")
        }
        // Use the platform finder's resolved URL even when duplicate/double-save
        // handling times out and reports no saved URL. Download handoff is an
        // independent consequence of resolving downloadable media.
        let media: IntentFile?
        if let downloadURLString = resolvedPlatformURLString ?? savedURLString {
            media = try await downloadMedia(
                for: downloadURLString, reporter: reporter)
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

    /// Resumes a checkpoint emitted by Provide Context. Invalid, unknown, or
    /// empty metadata deliberately returns nil, so Save falls back to the
    /// screenshot flow above, preserving manually configured shortcuts.
    private func resumeFromMetadataIfPossible(
        reporter: IntentProgressReporter
    ) async throws -> (value: SaveResultEntity, dialog: IntentDialog)? {
        guard let state = CaptureIntentMetadata.decode(metadata) else { return nil }
        if let encodedApp = state.currentApp,
           encodedApp.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(
                    currentApp.trimmingCharacters(in: .whitespacesAndNewlines)) != .orderedSame {
            SharedDiagnosticLog.record(
                "save: metadata current app differs from input; using CurrentApp input",
                category: "intents")
        }

        switch state.phase {
        case .screenshot:
            return nil
        case .save:
            guard let prepared = state.preparedSave else { return nil }
            reporter.enter(.saving)
            let outcome = await IntentIngestHelper.performPreparedSavePress(
                prepared, waitForCancelledFastPath: true)
            let savedURLString = try self.savedURLString(from: outcome)
                ?? state.resolvedURLString
                ?? prepared.urlString
            if let exported = await Self.exportedFile(from: outcome) {
                IntentIngestHelper.finishSaveAttempt(urlString: savedURLString)
                reporter.enter(.finishing)
                return (SaveResultEntity(media: exported), "Done.")
            }
            if let comparison = await comparisonMedia(
                for: savedURLString, reporter: reporter) {
                IntentIngestHelper.finishSaveAttempt(urlString: savedURLString)
                reporter.enter(.finishing)
                return (SaveResultEntity(media: comparison), "Saved to Luna.")
            }
            let media = try await downloadMedia(
                for: savedURLString, checkpoint: state.media,
                reporter: reporter)
            if case .friendPromptRequested = outcome {
                try? await requestToContinueInForeground()
            }
            IntentIngestHelper.finishSaveAttempt(urlString: savedURLString)
            reporter.enter(.finishing)
            return (SaveResultEntity(media: media), "Saved to Luna.")
        case .download:
            guard let urlString = state.resolvedURLString else { return nil }
            let media = try await downloadMedia(
                for: urlString, checkpoint: state.media,
                reporter: reporter)
            IntentIngestHelper.finishSaveAttempt(urlString: urlString)
            reporter.enter(.finishing)
            return (SaveResultEntity(media: media), "Saved to Luna.")
        case .comparison:
            // The product and its alternative sellers are already saved; the
            // summary is what Provide Context ran out of time for. Under the
            // extended runtime this has room to refresh day-old seller prices
            // before it prints them.
            guard let urlString = state.resolvedURLString else { return nil }
            let media = await comparisonMedia(for: urlString, reporter: reporter)
            IntentIngestHelper.finishSaveAttempt(urlString: urlString)
            reporter.enter(.finishing)
            return (SaveResultEntity(media: media), "Saved to Luna.")
        }
    }

    /// The alternative-seller comparison document for a saved product, or nil
    /// for every save that isn't one (and in every app that doesn't track
    /// prices, where the seam is never installed).
    private func comparisonMedia(
        for urlString: String, reporter: IntentProgressReporter
    ) async -> IntentFile? {
        guard ActionButtonIntentSupport.handlesProductComparison else { return nil }
        reporter.enter(.findingSellers)
        return await ActionButtonIntentSupport.comparisonFile(for: urlString)
    }

    private func downloadMedia(
        for urlString: String,
        checkpoint: IntentMediaCheckpoint? = nil,
        reporter: IntentProgressReporter
    ) async throws -> IntentFile? {
        reporter.enter(.downloading)
        reporter.setExpectedBytes(checkpoint?.expectedByteCount)
        ActionButtonIntentSupport.byteProgress = { received, expected in
            reporter.setExpectedBytes(expected)
            reporter.setReceivedBytes(received)
        }
        defer { ActionButtonIntentSupport.byteProgress = nil }
        return try await ActionButtonIntentSupport.downloadMediaIfNeeded(
            for: urlString, checkpoint: checkpoint
        ) {
            try? await requestToContinueInForeground()
        }
    }

}
