//
//  ProvideContextIntent.swift
//  Luna
//
//  App Intent definition (kept in the app target for App Intents discovery).
//  The decision core is `LunaIntents.ProvideContextDecision`; this wrapper adds
//  the onboarding hijack, the immediate Safari save, and foregrounding.
//

import AppIntents
import LunaIntents
import LunaModels
import LunaMediaDownload
import LunaStorage
import Foundation
import UniformTypeIdentifiers

/// First step of the Action Button capture flow. Pass the current app (from
/// Get Current App); the intent decides what the Shortcut should do next and
/// returns a transient entity whose outcome is `.unhandled`, `.done`, or
/// `.requiresScreenshot`. A completed synchronous media download is attached
/// to the entity for the Shortcut to display or pass onward. Outside Safari,
/// compatible complete URLs supplied by the Shortcut are saved directly before
/// screenshot analysis is considered.
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

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .noTrackedPage:
                return "No Safari page tracked yet. Is the Luna extension enabled?"
            case .unsupportedKind(let message):
                return "\(message)"
            }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<ProvideContextResultEntity> {
        let isSafari = app.map { AppNamePlatform.isSafari(forAppName: $0) } ?? false

        // A complete URL supplied by Shortcuts takes precedence over every
        // app-based decision, including onboarding interception and an
        // otherwise unsupported current app. Safari deliberately ignores this
        // input and continues to use its extension-backed URL store below.
        if let urlString = ProvideContextOnScreenURL.collapseText(
            onScreenURLs,
            isSafari: isSafari,
            isEnabled: AppIntentSettings.handleOnScreenURLs
        ), let result = try await saveURL(
            urlString,
            unsupportedKindHandling: .fallBack
        ) {
            return .result(value: result)
        }

        // With no usable supplied URL, let the Action Button onboarding state
        // machine hijack this invocation if it's mid-flight for this surface.
        // Its first interception fires from the Shortcuts app (the freshly
        // imported shortcut's own first run); its second fires from wherever
        // the Action Button was actually pressed, once real setup is complete.
        if let app {
            let surface = AppSurfaceConfig.current.storageIdentifier
            switch ActionButtonOnboardingStore.shared.handleProvideContextInvoked(
                appName: app,
                isCurrentAppLuna: ActionButtonIntentSupport.isCurrentAppLuna(comparedTo: app),
                forSurface: surface
            ) {
            case .foregroundThenUnsupported:
                // Bounce the user back into Luna (in-app onboarding reacts to
                // the state change). A declined prompt remains unhandled.
                try? await requestToContinueInForeground()
                return .result(value: ProvideContextResultEntity(outcome: .unhandled))
            case .unsupported:
                return .result(value: ProvideContextResultEntity(outcome: .unhandled))
            case .none:
                break
            }
        }

        let decision = ProvideContextDecision.decide(
            appName: app,
            isSafari: isSafari,
            isShortcuts: app.map { AppNamePlatform.isShortcuts(forAppName: $0) } ?? false,
            platform: app.flatMap { AppNamePlatform.platform(forAppName: $0) },
            safariURLFresh: SafariURLStore.isFresh()
                && !(SafariURLStore.lastURL ?? "").isEmpty,
            // A recognized-platform save is media, so only media-handling apps
            // (Downloader, the central Luna app) proceed to a screenshot save.
            handlesMediaKind: AppSurfaceConfig.current.handlesMedia,
            visionModelAvailable: ScreenCaptureModelSessionFactory.makeDefault().isAvailable)

        switch decision {
        case .unsupported:
            return .result(value: ProvideContextResultEntity(outcome: .unhandled))
        case .screenshotNeeded:
            return .result(value: ProvideContextResultEntity(outcome: .requiresScreenshot))
        case .saveImmediately:
            guard let urlString = SafariURLStore.lastURL, !urlString.isEmpty else {
                // Shouldn't happen (freshness implies a URL) — but never save
                // nothing silently.
                throw ProvideContextError.noTrackedPage
            }
            guard let result = try await saveURL(
                urlString,
                unsupportedKindHandling: .throwError
            ) else {
                preconditionFailure("Throwing unsupported-kind handling cannot fall back")
            }
            return .result(value: result)
        }
    }

    private enum UnsupportedKindHandling: Equatable {
        case throwError
        case fallBack
    }

    /// The one immediate-URL path for both Safari-extension URLs and URLs
    /// extracted from Shortcuts input. A timeout still counts as handled: the
    /// normal ingest task continues and persists its pending work in the
    /// background. Only an explicit foreign-kind rejection can fall back.
    private func saveURL(
        _ urlString: String,
        unsupportedKindHandling: UnsupportedKindHandling
    ) async throws -> ProvideContextResultEntity? {
        let outcome = await IntentIngestHelper.handleSavePress(
            urlString: urlString,
            doubleSaveActionSurface: ActionButtonIntentSupport.doubleSaveSurface)

        let savedURLString: String
        switch outcome {
        case let .friendPromptRequested(savedURL):
            try? await requestToContinueInForeground()
            savedURLString = savedURL
        case let .completed(savedURL):
            // Nil means only that the 12-second race expired. The ingest task
            // continues, exactly as it does for a Safari-extension URL.
            savedURLString = savedURL ?? urlString
        case let .unsupportedKind(owner):
            guard unsupportedKindHandling == .throwError else { return nil }
            throw ProvideContextError.unsupportedKind(
                message: IntentIngestHelper.unsupportedDialogText(owner: owner))
        }

        let media = try await ActionButtonIntentSupport.downloadMediaIfNeeded(
            for: savedURLString
        ) {
            try? await requestToContinueInForeground()
        }
        return ProvideContextResultEntity(outcome: .done, media: media)
    }
}

/// Shared plumbing for the two Action Button intents (Provide Context + Save).
enum ActionButtonIntentSupport {

    enum MediaHandoffError: Error, CustomLocalizedStringResourceConvertible {
        case insufficientStorage(String)

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .insufficientStorage(let message): return "\(message)"
            }
        }
    }

    /// One media handoff shared by ProvideContext's completed Safari fast path
    /// and SaveIntent's screenshot/search path. `foreground` is invoked only
    /// when a first read/write Photos authorization prompt needs a visible host.
    static func downloadMediaIfNeeded(
        for urlString: String,
        foreground: () async -> Void
    ) async throws -> IntentFile? {
        guard MediaAutoDownloader.shouldStartDownloaderIntentDownload(
            forURLString: urlString)
        else {
            SharedDiagnosticLog.record(
                "intent media handoff skipped: handlesMedia=\(MediaAutoDownloader.isRunningInDownloader), supported=\(MediaDownloadablePlatform.supports(urlString))",
                category: "media-download")
            return nil
        }
        if DownloaderIntentPhotoPermission.requiresForegroundRequest {
            await foreground()
        }
        let photosAuthorized = await DownloaderIntentPhotoPermission.requestIfNeeded()
        if AutoDownloadSettings.returnMediaFromAppIntents,
           let existing = SavedMediaStore.shared.existingDownloadedItem(
               forURLString: urlString) {
            let media = await MediaAutoDownloader.exportFile(from: existing)
            return media.map { intentFile(for: $0) }
        }
        if AutoDownloadSettings.returnMediaFromAppIntents,
           let sourceURL = URL(string: urlString),
           let inspection = await MediaDownloadPreflight.inspect(sourceURL: sourceURL) {
            if let error = MediaDownloadPreflight.storageError(for: inspection) {
                throw MediaHandoffError.insufficientStorage(error.message)
            }
            guard IntentMediaDownloadPolicy.shouldAwait(
                expectedByteCount: inspection.expectedByteCount)
            else {
                let started = await MediaAutoDownloader.startDownloaderIntentDownload(
                    forURLString: urlString)
                SharedDiagnosticLog.record(
                    "intent media handoff: synchronous=false, reason=size, bytes=\(inspection.expectedByteCount.map(String.init) ?? "unknown"), started=\(started), photosAuthorized=\(photosAuthorized)",
                    category: "media-download")
                return nil
            }
            let media = await MediaAutoDownloader.downloadForDownloaderIntentAwaiting(
                forURLString: urlString)
            SharedDiagnosticLog.record(
                "intent media handoff: synchronous=true, bytes=\(inspection.expectedByteCount.map(String.init) ?? "unknown"), completed=\(media != nil), photosAuthorized=\(photosAuthorized)",
                category: "media-download")
            return media.map { intentFile(for: $0) }
        } else {
            let started = await MediaAutoDownloader.startDownloaderIntentDownload(
                forURLString: urlString)
            SharedDiagnosticLog.record(
                "intent media handoff: synchronous=false, started=\(started), photosAuthorized=\(photosAuthorized)",
                category: "media-download")
            return nil
        }
    }

    private static func intentFile(for media: DownloadedMedia) -> IntentFile {
        let type = UTType(filenameExtension: media.fileURL.pathExtension)
            ?? (media.kind == .video ? .mpeg4Movie : .image)
        return IntentFile(
            fileURL: media.fileURL,
            filename: media.fileURL.lastPathComponent,
            type: type)
    }

    /// The double-save action (send to Kindle / friend on a repeat press within
    /// 7 s) is armed only for the Reader app's Action Button saves — every other
    /// surface and save path keeps the plain save behavior.
    static var doubleSaveSurface: String? {
        guard AppSurfaceConfig.current == .reader else { return nil }
        return AppSurfaceConfig.current.storageIdentifier
    }

    /// Whether the "current app" reported by Shortcuts (`Get Current App`) is THIS
    /// Luna app — i.e. the Action Button was pressed while Luna itself was
    /// frontmost, so there's no need to bounce the user back to it. Compared
    /// case-insensitively against the running bundle's display/bundle name, plus a
    /// generic "Luna"-prefix match (covers "Luna", "Luna Reader", "Luna Downloader",
    /// "Luna Price Tracker" regardless of exactly how Shortcuts reports the name).
    static func isCurrentAppLuna(comparedTo appName: String) -> Bool {
        let name = appName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !name.isEmpty else { return false }
        if name.hasPrefix("luna") { return true }
        let displayName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)?
            .lowercased()
        let bundleName = (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)?
            .lowercased()
        return name == displayName || name == bundleName
    }
}
