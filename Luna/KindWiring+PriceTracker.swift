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

import LunaHTMLClassification
import LunaIngest
import LunaModels
import LunaPriceIngest
import LunaPriceUI
import LunaReadingList
import LunaReadingListUI
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
        IngestorKindHandlers.product = ProductKindHandler()
        // No price-graph email snapshot: Price Tracker shares a tracker as its
        // product link, never as a Luna email (see `LunaApp.sharesByEmail`).

        // Install the in-app "Read instead" behavior for the price-tracking editor
        // (shared with the extensions, which can't reference the ingestor): a
        // forced-article re-save, no re-detection back into a tracker.
        PriceTrackingViewController.defaultSaveAsArticle = { urlString in
            Task { await ReadingListIngestor.shared.saveAsArticle(urlString: urlString) }
        }
        // Price Tracker "no price" → "Ask Apple Intelligence" resolver (URL
        // Rescue Phase 6 UI).
        PriceTrackingViewController.intelligentPriceResolver = { urlString in
            guard let info = await URLRescueWiring.rescueProductInfo(urlString: urlString)
            else { return nil }
            return PriceTrackingViewController.ResolvedPrice(
                amount: info.priceAmount, currency: info.priceCurrency)
        }
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

    @MainActor
    private static func makeCompletedRootViewController() -> UIViewController {
        UINavigationController(rootViewController: ProductCardDeck.makeRoot())
    }

    @MainActor
    static func makeSetupReplayRootViewController() -> UIViewController {
        makeCompletedRootViewController()
    }

    static func mainNavigationController(of root: UIViewController) -> UINavigationController? {
        root as? UINavigationController
    }

    /// Price Tracker adds no kind rows — the universal tail is the whole menu.
    static func settingsCategories() -> [SettingsCategory] { [] }

    // MARK: - Lifecycle (called by AppDelegate/SceneDelegate at fixed points)

    static func appDidLaunch() {
        legacyOnboardingDemoSave.cleanup()
    }

    static func appDidEnterBackground() {
        // Keeps the Safari extension's history-pill data current even between
        // refresh cycles (e.g. after the user edits an alert threshold or
        // archives a tracker, neither of which triggers a refresh).
        PriceHistoryIndexWriter.regenerate()
    }

    static func sceneDidForeground() {}

    static func readingListDidChange() {}

    static func wifiBecameAvailable() {}

    /// Price Tracker handles no articles — ereader sends are never pending here.
    static func retryPendingArticleSends() {}

    static func resumeUnfinishedMediaDownloads() async {}

    static func attachBackgroundURLSessionHandler(_ completionHandler: @escaping () -> Void) {
        // No media kind → no background URLSession to reattach; complete the
        // callback immediately so the system isn't left waiting.
        completionHandler()
    }

    /// Price Tracker links no media module — no Live Activity, so this route
    /// never actually fires here, but `SceneDelegate` is universal.
    static func mediaDeepLinkAction(forURLString urlString: String) -> MediaDeepLinkAction { .none }

    /// Price Tracker's Safari extension resolves no video (the native handler
    /// gates on `hostHandlesMedia`), so nothing can ever queue a download for it.
    static func drainPendingResolvedMedia(returningToSource: Bool) {}

    /// Runs one price-refresh pass and returns the processed-tracker count.
    /// Non-nil only in product-handling apps; its presence is what arms the
    /// price-refresh BGTask registration/scheduling in AppDelegate.
    static let priceRefreshRunner: (() async -> Int)? = {
        await PriceRefreshCoordinator.shared.refreshAndNotify().count
    }

    #if DEBUG
    /// `-openArchive` is an article-app debug tool.
    static func debugArchiveReaderRoot(articleURL: URL) -> UIViewController? { nil }

    /// The kind-woven UI-test screen catalog compiles only into the central
    /// Luna app (the UI-test/screenshot host).
    static func uiTestRootViewController(named name: String) -> UIViewController? { nil }
    #endif
}

/// Bridges `IngestorProductHandling` to LunaPriceUI's `ProductTrackerIngestor`.
private struct ProductKindHandler: IngestorProductHandling {
    func ingestProductTracker(
        _ item: ReadingListItem, url: URL, product: ProductInfo, store: ReadingListStore
    ) async {
        await ProductTrackerIngestor.shared.ingest(item, url: url, product: product, store: store)
    }
}
