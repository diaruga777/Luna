//
//  KindWiring+PriceTracker.swift
//  Luna
//
//  Per-app composition root: registers exactly the per-kind processors,
//  ingestor handlers, and UI/lifecycle seams this app's target links. EXACTLY
//  ONE KindWiring variant is compiled into each app target (the other variants
//  are excluded via the synchronized group's per-target membership exceptions)
//  — the registries and the static lifecycle API below mirror the link set.
//

import LunaIngest
import LunaModels
import LunaPriceUI
import LunaStorage
import UIKit

enum KindWiring {
    /// Migration only — onboarding stores nothing (see `OnboardingLegacyDemoSave`).
    private static let legacyOnboardingDemoSave =
        PriceTrackerOnboardingDemoSave.legacyCleanup

    @MainActor
    static func install() {
        #if DEBUG
        AppOnboardingStore.shared.resetIfRequested()
        // Staged mode's catalogs — this app's kinds only (`claudedocs/staging.md`).
        SharedStageCatalog.install()
        ProductStageCatalog.install()
        #endif

        ProductKindComposition.install()
        // The product kind's CARD half, on the same principle — the one
        // definition the central app installs too (`CardKindPresenter.swift`).
        CardKindPresenters.product = ProductCardPresenter()
        // …and the product kind's half of the app shell, which the central app
        // installs from the same file (`ProductShellWiring`).
        ProductShellWiring.install()
        // No price-graph email snapshot: Price Tracker shares a tracker as its
        // product link, never as a Luna email (see `LunaApp.sharesByEmail`).
    }

    // MARK: - Root UI shape

    /// The Price Tracker uses the same root card deck + archive tray as Reader
    /// and Downloader, without the article app's audio mini-player host. The deck
    /// is the shared host configured by `ProductCardDeck`; this app has no deck
    /// subclass of its own.
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

    /// Price Tracker adds no kind rows — the universal tail is the whole menu.
    static func settingsCategories() -> [SettingsCategory] { [] }

    // MARK: - Lifecycle (called by AppDelegate/SceneDelegate at fixed points)

    static func appDidLaunch() {
        legacyOnboardingDemoSave.cleanup()
        ProductShellWiring.appDidLaunch()
    }

    static func appDidEnterBackground() {
        ProductShellWiring.appDidEnterBackground()
    }

    static func sceneDidForeground() {}

    static func readingListDidChange() {}

    static func wifiBecameAvailable() {}

    /// Price Tracker handles no articles — ereader sends are never pending here.
    static func retryPendingArticleSends() {}

    static func attachBackgroundURLSessionHandler(_ completionHandler: @escaping () -> Void) {
        // No media kind → no background URLSession to reattach; complete the
        // callback immediately so the system isn't left waiting.
        completionHandler()
    }

    /// Price Tracker links no media module — no Live Activity, so this route
    /// never actually fires here, but `SceneDelegate` is universal.
    static func mediaDeepLinkAction(forURLString urlString: String) -> MediaDeepLinkAction { .none }

    /// …and so nothing here can produce a downloaded file to share either.
    static let mediaShareFileExporter: MediaShareFileExporting? = nil

    /// Price Tracker's Safari extension resolves no video (the native handler
    /// gates on `hostHandlesMedia`), so nothing can ever queue a download for it.
    static func drainPendingResolvedMedia(returningToSource: Bool) {}

    /// Runs one price-refresh pass and returns the processed-tracker count.
    /// Non-nil only in product-handling apps; its presence is what arms the
    /// price-refresh BGTask registration/scheduling in AppDelegate.
    static let priceRefreshRunner: (() async -> Int)? = ProductShellWiring.priceRefreshRunner

    #if DEBUG
    /// `-openArchive` is an article-app debug tool.
    static func debugArchiveReaderRoot(articleURL: URL) -> UIViewController? { nil }
    #endif
}
