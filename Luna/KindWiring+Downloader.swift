//
//  KindWiring+Downloader.swift
//  Luna
//
//  Per-app composition root. It registers the per-kind processors, ingestor
//  handlers, and UI/lifecycle seams this app's target links. Each app target
//  compiles exactly one `KindWiring` variant — the synchronized group excludes
//  the others by membership exception — so the registries and the static
//  lifecycle API below mirror this app's own link set.
//

import LunaMediaDownload
import LunaModels
import LunaSaves
import LunaStorage
import UIKit

enum KindWiring {
    /// Migration only — onboarding stores nothing (see `OnboardingLegacyDemoSweeping`).
    private static let legacyOnboardingDemoSave =
        DownloaderOnboardingDemoSave.legacyCleanup

    @MainActor
    static func install() {
        // The Luna file intake seam. Every root installs a witness, so a
        // `.luna` file reaching a surface is always accounted for; the
        // recovery and plugin surfaces replace it with their own.
        LunaFileIntake.recoveryHandler = UnsupportedLunaFileIntake()
        LunaFileIntake.pluginHandler = UnsupportedLunaFileIntake()
        #if DEBUG
        AppOnboardingStore.shared.resetIfRequested()
        // Staged mode's catalogs, for this app's kinds only
        // (`claudedocs/staging.md`).
        SharedStageCatalog.install()
        MediaStageCatalog.install()
        #endif

        // The media kind pack: one call, shared verbatim with the
        // Downloader's share and action extensions. See
        // `MediaKindComposition`, which also states that media needs no
        // web-processing pipeline stage — platform recognition is URL-only
        // classification.
        MediaKindComposition.install()
        // The media kind's card half follows the same rule — the one
        // definition the central app installs too. See `CardKindPresenter.swift`.
        CardKindPresenters.media = MediaCardPresenter()
        // The media kind's app-shell half installs from the same file the
        // central app uses (`MediaShellWiring`).
        MediaShellWiring.install()
    }

    // MARK: - Root UI shape

    /// The saved-media card deck in a bare nav controller, with no audio
    /// mini-player host — read-aloud is an article-app feature. `MediaCardDeck`
    /// configures the shared deck host; this app has no deck subclass of its
    /// own.
    @MainActor
    static func makeRootViewController() -> UIViewController {
        UINavigationController(rootViewController: MediaCardDeck.makeRoot())
    }

    static func mainNavigationController(of root: UIViewController) -> UINavigationController? {
        root as? UINavigationController
    }

    static func openPriceTrackerAddSeller(
        itemID: UUID, navigationController: UINavigationController
    ) {}

    static func settingsCategories() -> [SettingsCategory] {
        [
            SettingsCategory(title: L10n.string("Common_downloads"), symbol: "play.fill") {
                DownloadsSettingsScreen()
            },
        ]
    }

    // MARK: - Lifecycle (called by AppDelegate/SceneDelegate at fixed points)

    static func drainPendingResolvedMedia(returningToSource: Bool) {
        MediaShellWiring.drainPendingResolvedMedia(returningToSource: returningToSource)
    }

    /// Central Luna only (`claudedocs/plans/plugin-platform.md` §2.1);
    /// Downloader runs no plugin platform, so its own queue can never hold
    /// anything.
    static func drainPendingPluginModels(returningToSource: Bool) {}

    /// Central Luna only; Downloader's Safari extension never creates this handoff.
    static func openPendingPluginRecoveryWorkshop(caseID: UUID) {}

    /// The extension's LLM hand-off, arriving as `<scheme>://llm?item=…` when
    /// the extension's own open was refused. WP2 opens the recorded provider
    /// URL from here; the route exists now so every app answers it.
    static func openLLMHandoff(itemID: UUID) {}

    static func appDidLaunch() {
        legacyOnboardingDemoSave.sweepLegacyDemoSave()
        MediaShellWiring.appDidLaunch()
    }

    static func appDidEnterBackground() {
        MediaShellWiring.appDidEnterBackground()
    }

    static func sceneDidForeground() {
        MediaShellWiring.sceneDidForeground()
        // This may be the first time this process sees Wi-Fi since a
        // download queued, so it resumes what the policy deferred. The
        // central app instead leaves that to the reachability notification.
        MediaShellWiring.resumePendingWiFiDownloads()
    }

    static func savesDidChange() {
        MediaShellWiring.savesDidChange()
    }

    static func wifiBecameAvailable() {
        MediaShellWiring.resumePendingWiFiDownloads()
    }

    /// Downloader handles no articles, so ereader sends are never pending
    /// here.
    static func retryPendingArticleSends() {}

    static func attachBackgroundURLSessionHandler(
        identifier: String, _ completionHandler: @escaping () -> Void
    ) {
        MediaShellWiring.attachBackgroundURLSessionHandler(identifier: identifier, completionHandler)
    }

    static func mediaDeepLinkAction(forURLString urlString: String) -> MediaDeepLinkAction {
        MediaShellWiring.deepLinkAction(forURLString: urlString)
    }

    static let mediaShareFileExporter: (any MediaShareFileExporting)? =
        MediaShellWiring.shareFileExporter

    /// Downloader handles no products, so there is no runner. AppDelegate
    /// never registers or schedules the price-refresh BGTask.
    static let priceRefreshRunner: (any PriceRefreshRunning)? = nil

    #if DEBUG
    /// `-openArchive` is an article-app debug tool.
    static func debugArchiveReaderRoot(articleURL: URL) -> UIViewController? { nil }
    #endif
}
