//
//  KindWiring+PriceTracker.swift
//  Luna
//
//  Per-app composition root. It registers the per-kind processors, ingestor
//  handlers, and UI/lifecycle seams this app's target links. Each app target
//  compiles exactly one `KindWiring` variant — the synchronized group excludes
//  the others by membership exception — so the registries and the static
//  lifecycle API below mirror this app's own link set.
//

import LunaIngest
import LunaModels
import LunaPriceUI
import LunaStorage
import UIKit

enum KindWiring {
    /// Migration only — onboarding stores nothing (see `OnboardingLegacyDemoSweeping`).
    private static let legacyOnboardingDemoSave =
        PriceTrackerOnboardingDemoSave.legacyCleanup

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
        ProductStageCatalog.install()
        #endif

        ProductKindComposition.install()
        // The product kind's card half follows the same rule — the one
        // definition the central app installs too. See `CardKindPresenter.swift`.
        CardKindPresenters.product = ProductCardPresenter()
        // The product kind's app-shell half installs from the same file the
        // central app uses (`ProductShellWiring`).
        ProductShellWiring.install()
        // Price Tracker installs no price-graph email snapshot: it shares a
        // tracker as its product link, never as a Luna email. See
        // `LunaApp.sharesByEmail`.
    }

    // MARK: - Root UI shape

    /// Price Tracker uses the same root card deck and archive tray as Reader
    /// and Downloader, without the article app's audio mini-player host.
    /// `ProductCardDeck` configures the shared deck host; this app has no
    /// deck subclass of its own.
    @MainActor
    static func makeRootViewController() -> UIViewController {
        UINavigationController(rootViewController: ProductCardDeck.makeRoot())
    }

    static func mainNavigationController(of root: UIViewController) -> UINavigationController? {
        root as? UINavigationController
    }

    @MainActor
    static func openPriceTrackerAddSeller(
        itemID: UUID, navigationController: UINavigationController
    ) {
        ProductShellWiring.openAddSeller(
            itemID: itemID, navigationController: navigationController)
    }

    /// Price Tracker adds no kind rows. The universal tail is the whole menu.
    static func settingsCategories() -> [SettingsCategory] { [] }

    // MARK: - Lifecycle (called by AppDelegate/SceneDelegate at fixed points)

    static func appDidLaunch() {
        legacyOnboardingDemoSave.sweepLegacyDemoSave()
        ProductShellWiring.appDidLaunch()
    }

    static func appDidEnterBackground() {
        ProductShellWiring.appDidEnterBackground()
    }

    static func sceneDidForeground() {}

    static func savesDidChange() {}

    static func wifiBecameAvailable() {}

    /// Price Tracker handles no articles, so ereader sends are never pending
    /// here.
    static func retryPendingArticleSends() {}

    static func attachBackgroundURLSessionHandler(
        identifier: String, _ completionHandler: @escaping () -> Void
    ) {
        // Price Tracker links no media kind, so there is no background
        // URLSession to reattach. It completes the callback immediately so
        // the system isn't left waiting.
        completionHandler()
    }

    /// Price Tracker links no media module, so it has no Live Activity and
    /// this route never actually fires. `SceneDelegate` is universal, so the
    /// method must still exist.
    static func mediaDeepLinkAction(forURLString urlString: String) -> MediaDeepLinkAction { .none }

    /// Price Tracker produces no downloaded file, so it has nothing to share.
    static let mediaShareFileExporter: (any MediaShareFileExporting)? = nil

    /// Price Tracker's Safari extension resolves no video (the native handler
    /// gates on `hostHandlesMedia`), so nothing can ever queue a download for
    /// it.
    static func drainPendingResolvedMedia(returningToSource: Bool) {}

    /// Central Luna only (`claudedocs/plans/plugin-platform.md` §2.1); Price
    /// Tracker runs no plugin platform, so its own queue can never hold
    /// anything.
    static func drainPendingPluginModels(returningToSource: Bool) {}

    /// Central Luna only; Price Tracker's Safari extension never creates this handoff.
    static func openPendingPluginRecoveryWorkshop(caseID: UUID) {}

    /// The extension's LLM hand-off, arriving as `<scheme>://llm?item=…` when
    /// the extension's own open was refused. WP2 opens the recorded provider
    /// URL from here; the route exists now so every app answers it.
    static func openLLMHandoff(itemID: UUID) {}

    /// Runs one price-refresh pass and returns the processed-tracker count.
    /// Non-nil only in product-handling apps; its presence is what arms the
    /// price-refresh BGTask registration/scheduling in AppDelegate.
    static let priceRefreshRunner: (any PriceRefreshRunning)? =
        ProductShellWiring.priceRefreshRunner

    #if DEBUG
    /// `-openArchive` is an article-app debug tool.
    static func debugArchiveReaderRoot(articleURL: URL) -> UIViewController? { nil }
    #endif
}
