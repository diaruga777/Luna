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

/// First step of the Action Button capture flow. Pass the current app (from
/// Get Current App); the intent decides what the Shortcut should do next and
/// returns:
///
/// - **0** — unsupported: nothing to capture here; the Shortcut just exits.
/// - **1** — saved: Safari with a fresh tracked page URL; the intent saved it
///   itself through the action-button save path (double-save preserved). Done.
/// - **2** — screenshot needed: the Shortcut should take a screenshot and pass
///   it (plus the app name) to the Save intent.
struct ProvideContextIntent: AppIntent, ForegroundContinuableIntent {
    init() {}
    static let title: LocalizedStringResource = "Provide Context"
    static let description = IntentDescription("""
        First step of the Action Button shortcut. Pass the current app (from Get \
        Current App). Returns 0 when there's nothing to capture (stop), 1 when \
        the current Safari page was saved directly (done), and 2 when a \
        screenshot is needed (take one and pass it to Save).
        """)
    static let openAppWhenRun: Bool = false

    @Parameter(title: "App", description: "The current app, from Get Current App.")
    var app: String?

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

    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
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
                // the state change). A declined prompt still returns 0.
                try? await requestToContinueInForeground()
                return .result(value: 0)
            case .unsupported:
                return .result(value: 0)
            case .none:
                break
            }
        }

        let decision = ProvideContextDecision.decide(
            appName: app,
            isSafari: app.map { AppNamePlatform.isSafari(forAppName: $0) } ?? false,
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
            return .result(value: 0)
        case .screenshotNeeded:
            return .result(value: 2)
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
                // surfaced on this fast path — it returns a bare Int for the
                // Shortcut; the saved item still appears once the app exists.
                break
            case let .blockedByInterop(owner, _):
                // Unpaid cross-surface save: the item was discarded — surface
                // the unlock dialog instead of a silent nothing.
                throw ProvideContextError.interopBlocked(
                    message: IntentIngestHelper.blockedDialogText(
                        owner: owner,
                        currentAppName: InteropSurface.current.displayName))
            }
            // Return-1 is the complete Safari fast path: it never invokes
            // SaveIntent, so it must hand downloadable tracked URLs to the
            // Downloader background manager itself. This runs only AFTER the
            // interop switch: a blocked save must not start downloader work.
            await ActionButtonIntentSupport.startDownloaderDownloadIfNeeded(
                for: urlString
            ) {
                try? await requestToContinueInForeground()
            }
            return .result(value: 1)
        }
    }
}

/// Shared plumbing for the two Action Button intents (Provide Context + Save).
enum ActionButtonIntentSupport {

    /// One media handoff shared by ProvideContext's return-1 Safari fast path
    /// and SaveIntent's screenshot/search path. `foreground` is invoked only
    /// when a first read/write Photos authorization prompt needs a visible host.
    static func startDownloaderDownloadIfNeeded(
        for urlString: String,
        foreground: () async -> Void
    ) async {
        guard MediaAutoDownloader.shouldStartDownloaderIntentDownload(
            forURLString: urlString)
        else {
            SharedDiagnosticLog.record(
                "intent media handoff skipped: downloaderInstalled=\(LunaInstallationMarkers.downloaderWasInstalled), supported=\(MediaDownloadablePlatform.supports(urlString))",
                category: "media-download")
            return
        }
        if DownloaderIntentPhotoPermission.requiresForegroundRequest {
            await foreground()
        }
        let photosAuthorized = await DownloaderIntentPhotoPermission.requestIfNeeded()
        let started = await MediaAutoDownloader.startDownloaderIntentDownload(
            forURLString: urlString)
        SharedDiagnosticLog.record(
            "intent media handoff: started=\(started), photosAuthorized=\(photosAuthorized)",
            category: "media-download")
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
