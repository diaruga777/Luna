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
import LunaInterop
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
        description: "URLs detected on screen. Compatible complete values may be saved directly.")
    var onScreenURLs: [String]?

    enum ProvideContextError: Error, CustomLocalizedStringResourceConvertible {
        case noTrackedPage
        /// Unpaid cross-surface save (`claudedocs/interop-purchase.md`) — the
        /// item was discarded; the dialog names the owning app and the unlock.
        case interopBlocked(message: String)

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .noTrackedPage:
                return "No Safari page tracked yet. Is the Luna extension enabled?"
            case .interopBlocked(let message):
                return "\(message)"
            }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<ProvideContextResultEntity> {
        // Before any decision work: let the Action Button onboarding state
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

        let isSafari = app.map { AppNamePlatform.isSafari(forAppName: $0) } ?? false
        if let urlString = ProvideContextOnScreenURL.collapse(
            onScreenURLs,
            isSafari: isSafari
        ), let result = await saveOnScreenURLIfPossible(urlString) {
            return .result(value: result)
        }

        let decision = ProvideContextDecision.decide(
            appName: app,
            isSafari: isSafari,
            isShortcuts: app.map { AppNamePlatform.isShortcuts(forAppName: $0) } ?? false,
            platform: app.flatMap { AppNamePlatform.platform(forAppName: $0) },
            safariURLFresh: SafariURLStore.isFresh()
                && !(SafariURLStore.lastURL ?? "").isEmpty,
            // All recognized platforms are Downloader-owned today.
            owningSurfaceInstalled: AppSurfaceConfig.current == .downloader
                || InstalledAppMarkers.isInstalled(.downloader),
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
            let outcome = await IntentIngestHelper.handleSavePress(
                urlString: urlString,
                doubleSaveActionSurface: ActionButtonIntentSupport.doubleSaveSurface
            )
            switch outcome {
            case .friendPromptRequested:
                // Double save with "ask every time": the pending friend prompt
                // is recorded; foreground Luna so the selector can appear.
                try? await requestToContinueInForeground()
            case .completed:
                // `needsInstallOwner` (paid, owning app missing) is not
                // surfaced on this fast path; the saved item still appears
                // once the app exists.
                break
            case let .blockedByInterop(owner, _):
                // Unpaid cross-surface save: the item was discarded — surface
                // the unlock dialog instead of a silent nothing.
                throw ProvideContextError.interopBlocked(
                    message: IntentIngestHelper.blockedDialogText(
                        owner: owner,
                        currentAppName: InteropSurface.current.displayName))
            }
            // The complete Safari fast path never invokes
            // SaveIntent, so it must hand downloadable tracked URLs to the
            // Downloader itself. This runs only AFTER the interop switch: a
            // blocked save must not start downloader work.
            let media = await ActionButtonIntentSupport.downloadMediaIfNeeded(
                for: urlString
            ) {
                try? await requestToContinueInForeground()
            }
            return .result(value: ProvideContextResultEntity(outcome: .done, media: media))
        }
    }

    /// Opportunistically saves a complete URL supplied by Shortcuts. A normal
    /// network enrichment failure still counts as saved because the ingest path
    /// has already persisted the row. Interop rejection and an undetermined
    /// timeout return nil so the caller follows the preexisting screenshot path.
    private func saveOnScreenURLIfPossible(
        _ urlString: String
    ) async -> ProvideContextResultEntity? {
        let outcome = await IntentIngestHelper.handleSavePress(
            urlString: urlString,
            doubleSaveActionSurface: ActionButtonIntentSupport.doubleSaveSurface)
        guard let success = ProvideContextOnScreenSave.success(from: outcome) else {
            return nil
        }
        if success.requiresForeground {
            try? await requestToContinueInForeground()
        }
        let media = await ActionButtonIntentSupport.downloadMediaIfNeeded(
            for: success.urlString
        ) {
            try? await requestToContinueInForeground()
        }
        return ProvideContextResultEntity(outcome: .done, media: media)
    }
}

/// Shared plumbing for the two Action Button intents (Provide Context + Save).
enum ActionButtonIntentSupport {

    /// One media handoff shared by ProvideContext's completed Safari fast path
    /// and SaveIntent's screenshot/search path. `foreground` is invoked only
    /// when a first read/write Photos authorization prompt needs a visible host.
    static func downloadMediaIfNeeded(
        for urlString: String,
        foreground: () async -> Void
    ) async -> IntentFile? {
        guard MediaAutoDownloader.shouldStartDownloaderIntentDownload(
            forURLString: urlString)
        else {
            SharedDiagnosticLog.record(
                "intent media handoff skipped: downloaderInstalled=\(LunaInstallationMarkers.downloaderWasInstalled), supported=\(MediaDownloadablePlatform.supports(urlString))",
                category: "media-download")
            return nil
        }
        if DownloaderIntentPhotoPermission.requiresForegroundRequest {
            await foreground()
        }
        let photosAuthorized = await DownloaderIntentPhotoPermission.requestIfNeeded()
        if AutoDownloadSettings.returnMediaFromAppIntents {
            let media = await MediaAutoDownloader.downloadForDownloaderIntentAwaiting(
                forURLString: urlString)
            SharedDiagnosticLog.record(
                "intent media handoff: synchronous=true, completed=\(media != nil), photosAuthorized=\(photosAuthorized)",
                category: "media-download")
            guard let media else { return nil }
            let type = UTType(filenameExtension: media.fileURL.pathExtension)
                ?? (media.kind == .video ? .mpeg4Movie : .image)
            return IntentFile(
                fileURL: media.fileURL,
                filename: media.fileURL.lastPathComponent,
                type: type)
        } else {
            let started = await MediaAutoDownloader.startDownloaderIntentDownload(
                forURLString: urlString)
            SharedDiagnosticLog.record(
                "intent media handoff: synchronous=false, started=\(started), photosAuthorized=\(photosAuthorized)",
                category: "media-download")
            return nil
        }
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
