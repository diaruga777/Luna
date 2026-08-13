//
//  ProductShellWiring.swift
//  Luna
//
//  The product kind's half of the app shell: every seam a product-handling app
//  installs at launch, and the lifecycle work price trackers owe at each of
//  `KindWiring`'s fixed points. Compiled ONLY into the targets that link the
//  product kind (Luna, LunaPriceTracker) — the other two exclude this file by
//  membership exception, exactly as they exclude `PriceTracker/
//  ProductCardPresenter.swift` and the rest of the product shell.
//
//  A `KindWiring+<App>` variant installs the product KIND PACK
//  (`ProductKindComposition`) and the product CARD presenter itself, then calls
//  the legs below; nothing product-specific is written twice.
//

import LunaHTMLClassification
import LunaModels
import LunaPriceUI
import LunaReadingList
import LunaStorage
import UIKit

enum ProductShellWiring {

    @MainActor
    static func install() {
        IngestorKindHandlers.product = ProductKindHandler()
        // A re-save that merges into a tracker which has never been through
        // a fan-out (still fewer than two stores) kicks a comparison instead
        // of showing nothing forever — `LunaReadingList` cannot link
        // `LunaPriceUI`, so this is the bridge (`claudedocs/price-comparison.md`).
        ReadingListIngestor.priceTrackerComparisonKicker = ResaveComparisonKicker()
        // Action Button intents hand a saved product back as its comparison
        // summary (`claudedocs/price-comparison.md`).
        ProductIntentHandoff.install()
        // Price Tracker "no price" → "Ask Apple Intelligence" resolver (URL
        // Rescue Phase 6 UI).
        ProductPriceRescue.resolver = URLRescuePriceResolver()
    }

    // MARK: - Lifecycle

    static func appDidLaunch() {
        // A save-time seller fan-out that never finished — a share extension is
        // torn down the moment the user is done with it — is resumed here, from
        // the pending marker the tracker carries (`claudedocs/price-comparison.md`).
        // Product snapshots are NOT swept here: they are read once, on the
        // save path, when a tracker is created (`claudedocs/price-tracking.md`).
        Task {
            await SellerComparison.completePending(store: ReadingListStore.shared)
        }
    }

    static func appDidEnterBackground() {
        // Keeps the Safari extension's history-pill data current even between
        // refresh cycles (e.g. after the user edits an alert threshold or
        // archives a tracker, neither of which triggers a refresh).
        PriceHistoryIndexWriter.regenerate()
    }

    /// Runs one price-refresh pass and returns the processed-tracker count. Its
    /// presence on `KindWiring` is what arms the price-refresh BGTask
    /// registration/scheduling in AppDelegate.
    static let priceRefreshRunner: any PriceRefreshRunning = PriceRefreshPass()

    /// The installed product leg of the price-refresh background job.
    private struct PriceRefreshPass: PriceRefreshRunning {
        func runPriceRefresh() async -> Int {
            await PriceRefreshCoordinator.shared.refreshAndNotify().count
        }
    }

    /// Brings the tracker's card to the centre of the deck and opens its
    /// add-seller sheet — the Action Button intent's "add a seller" route.
    @MainActor
    static func openAddSeller(itemID: UUID, navigationController: UINavigationController) {
        guard ReadingListStore.shared.item(withID: itemID)?.priceTracker != nil,
              let deck = navigationController.viewControllers.first
                as? CardCarouselHostViewController else { return }
        navigationController.dismiss(animated: false)
        navigationController.popToRootViewController(animated: false)
        deck.requestCentering(onSlotID: itemID)
        deck.reload()
        PriceTrackerAddSellerRoute.request(itemID: itemID)
    }
}

/// The price editors' "Ask Apple Intelligence to find the price" leg: URL
/// Rescue's product resolution, mapped onto the price the editor needs. Only the
/// app installs one, so an extension never makes the offer.
private struct URLRescuePriceResolver: ProductPriceResolving {
    func resolvePrice(forURLString urlString: String) async -> ProductPriceRescue.ResolvedPrice? {
        guard let info = await URLRescueWiring.rescueProductInfo(urlString: urlString)
        else { return nil }
        return ProductPriceRescue.ResolvedPrice(
            amount: info.priceAmount, currency: info.priceCurrency)
    }
}

/// Bridges `IngestorProductHandling` to LunaPriceUI's `ProductTrackerIngestor`.
/// The re-save bridge: `LunaReadingList` cannot link `LunaPriceUI`, so the
/// composition root carries the fan-out call.
private struct ResaveComparisonKicker: PriceTrackerComparisonKicking {
    func kickComparison(itemID: UUID, url: URL, store: ReadingListStore) {
        SellerComparison.beginAndRunInBackground(itemID: itemID, sourceURL: url, store: store)
    }
}

private struct ProductKindHandler: IngestorProductHandling {
    func ingestProductTracker(
        _ item: ReadingListItem, url: URL, product: ProductInfo, store: ReadingListStore
    ) async {
        await ProductTrackerIngestor.shared.ingest(item, url: url, product: product, store: store)
    }
}
