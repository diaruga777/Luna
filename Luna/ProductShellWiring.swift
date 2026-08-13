//
//  ProductShellWiring.swift
//  Luna
//
//  The product kind's half of the app shell. It installs every seam a
//  product-handling app needs at launch, and does the lifecycle work price
//  trackers owe at each of `KindWiring`'s fixed points. Only the targets that
//  link the product kind compile this file — Luna and LunaPriceTracker. The
//  other two exclude it by membership exception, the same way they exclude
//  `PriceTracker/ProductCardPresenter.swift` and the rest of the product shell.
//
//  A `KindWiring+<App>` variant installs the product kind pack
//  (`ProductKindComposition`) and the product card presenter itself, then
//  calls the legs below. Nothing product-specific is written twice.
//

import LunaHTMLClassification
import LunaModels
import LunaPriceUI
import LunaSaves
import LunaStorage
import UIKit

enum ProductShellWiring {

    @MainActor
    static func install() {
        IngestorKindHandlers.product = ProductKindHandler()
        // A re-save that merges into a tracker with fewer than two stores —
        // one that never ran a fan-out — kicks off a comparison instead of
        // showing nothing forever. `LunaSaves` cannot link `LunaPriceUI`, so
        // this closure bridges the two. See `claudedocs/price-comparison.md`.
        SavesIngestor.priceTrackerComparisonKicker = ResaveComparisonKicker()
        // Action Button intents hand a saved product back as its comparison
        // summary. See `claudedocs/price-comparison.md`.
        ProductIntentHandoff.install()
        // Resolves the Price Tracker's "no price" screen through "Ask Apple
        // Intelligence" — URL Rescue's Phase 6 UI.
        ProductPriceRescue.resolver = URLRescuePriceResolver()
    }

    // MARK: - Lifecycle

    static func appDidLaunch() {
        // Resumes a save-time seller fan-out that never finished — a share
        // extension is torn down the moment the user is done with it — from
        // the pending marker the tracker carries. See
        // `claudedocs/price-comparison.md`.
        //
        // Product snapshots are not swept here. They are read once, on the
        // save path, when a tracker is created. See
        // `claudedocs/price-tracking.md`.
        Task {
            await SellerComparison.completePending(store: SavesStore.shared)
        }
    }

    static func appDidEnterBackground() {
        // Keeps the Safari extension's history-pill data current between
        // refresh cycles — for example after the user edits an alert
        // threshold or archives a tracker, neither of which triggers a
        // refresh.
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

    /// Brings the tracker's card to the center of the deck and opens its
    /// add-seller sheet. This is the Action Button intent's "add a seller"
    /// route.
    @MainActor
    static func openAddSeller(itemID: UUID, navigationController: UINavigationController) {
        guard SavesStore.shared.item(withID: itemID)?.priceTracker != nil,
              let deck = navigationController.viewControllers.first
                as? CardCarouselHostViewController else { return }
        navigationController.dismiss(animated: false)
        navigationController.popToRootViewController(animated: false)
        deck.requestCentering(onSlotID: itemID)
        deck.reload()
        PriceTrackerAddSellerRoute.request(itemID: itemID)
    }
}

/// The price editors' "Ask Apple Intelligence to find the price" leg. It maps
/// URL Rescue's product resolution onto the price the editor needs. Only the
/// app installs one, so an extension never makes the offer.
private struct URLRescuePriceResolver: ProductPriceResolving {
    func resolvePrice(forURLString urlString: String) async -> ProductPriceRescue.ResolvedPrice? {
        guard let info = await URLRescueWiring.rescueProductInfo(urlString: urlString)
        else { return nil }
        return ProductPriceRescue.ResolvedPrice(
            amount: info.priceAmount, currency: info.priceCurrency)
    }
}

/// The re-save bridge: `LunaSaves` cannot link `LunaPriceUI`, so this struct
/// carries the fan-out call the composition root installs above.
private struct ResaveComparisonKicker: PriceTrackerComparisonKicking {
    func kickComparison(itemID: UUID, url: URL, store: SavesStore) {
        SellerComparison.beginAndRunInBackground(itemID: itemID, sourceURL: url, store: store)
    }
}

/// Bridges `IngestorProductHandling` to LunaPriceUI's `ProductTrackerIngestor`.
private struct ProductKindHandler: IngestorProductHandling {
    func ingestProductTracker(
        _ item: SavedItem, url: URL, product: ProductInfo, store: SavesStore
    ) async {
        await ProductTrackerIngestor.shared.ingest(item, url: url, product: product, store: store)
    }
}
