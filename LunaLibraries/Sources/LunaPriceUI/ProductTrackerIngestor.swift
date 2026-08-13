//
//  ProductTrackerIngestor.swift
//  LunaPriceUI
//

import LunaDesignSystem
import LunaFetch
import LunaHTMLClassification
import LunaModels
import LunaPriceCompare
import LunaSocial
import LunaStorage
import UIKit

/// Product-kind ingestion, extracted from `SavesIngestor` so only
/// product-handling apps carry the tracker-matching and price machinery. The
/// app shell installs this behind `IngestorKindHandlers.product` (via a thin
/// adapter in its `KindWiring` variant).
public final class ProductTrackerIngestor {
    public static let shared = ProductTrackerIngestor()

    /// Test seam: which snapshot store history-seeding reads. Production reads
    /// the shared App Group one.
    var snapshotStore: ProductSnapshotStore = .shared
    /// Test seam: the immediate post-seed refresh.
    var refresher: any SingleTrackerRefreshing = CoordinatorTrackerRefresher()
    /// Test seam: the history-index regeneration `finishSeeding` fires right
    /// after persisting.
    var indexRegenerator: any PriceHistoryIndexRegenerating = PriceHistoryIndexRegenerator()
    /// Test seam: STARTING the save-time alternative-seller fan-out.
    var comparisonStarter: any SellerComparisonStarting = BackgroundSellerComparisonStarter()
    /// Test seam for the complete product-artwork pass.
    var artworkLoader: any ProductArtworkLoading = ProductTrackerArtworkLoader()

    public init() {}

    /// Turns a detected product page into a price tracker. Intelligent matching:
    /// if the product matches an existing tracker (by product id, else fuzzy
    /// name+brand), the new URL is MERGED into that tracker; otherwise a new
    /// tracker is created on this item.
    public func ingest(
        _ item: SavedItem, url: URL, product: ProductInfo, store: SavesStore
    ) async {
        // The merge decision (and its snapshot seeding + identifier union) is
        // shared with the extension's immediate-editor path — see
        // `ProductTrackerMerge`. This instance's own `snapshotStore`
        // (tests stub it per-instance) is passed straight through as a
        // parameter rather than bridged via a global.
        let outcome = ProductTrackerMerge.mergeIfPossible(
            product: product, url: url, excludingItemID: item.id, store: store,
            comparisonStarter: comparisonStarter, snapshotStore: snapshotStore)
        if case let .merged(matchID, highlightedURL) = outcome {
            // The tracker that won a merge may predate artwork collection. A
            // duplicate save is still a chance to repair it, so every tracker
            // gets the same product → header → favicon attempt.
            if var tracker = store.item(withID: matchID)?.priceTracker,
               tracker.imageFileName == nil,
               let data = await artworkLoader.artworkData(
                primaryURL: product.imageURL, pageURL: url) {
                tracker.imageFileName = writeArtwork(data, for: matchID, store: store)
                store.updatePriceTracker(tracker, for: matchID)
            }
            // The just-saved item was a duplicate route into an existing tracker;
            // drop its placeholder item so only the merged tracker remains.
            store.delete(item)
            PriceTrackerSaveAnnouncement.post(
                itemID: matchID, source: item.effectiveCaptureSource,
                isMerge: true, highlightedURL: highlightedURL)
            finishSeeding(itemID: matchID)
            return
        }

        // A brand-new tracker's alert threshold is a decision, not a constant: with
        // the notification prompt still unanswered the product is tracked with NO
        // alert (the editors offer to set one, which is the opt-in moment). Being
        // async here, this asks the SYSTEM rather than the cached latch — and
        // refreshes that latch for the synchronous surfaces on the way past.
        let notificationsRequested = await NotificationManager.refreshAuthorizationRequestedState()
        var tracker = PriceTracker(
            productName: product.name, stores: product.trackerStores(fallbackURL: url),
            brand: product.brand, productID: product.productID,
            identifiers: product.identifiers.merging(ProductIdentifiers(brand: product.brand)),
            alertThresholdFraction: PriceAlertThresholdPolicy.initialThresholdFraction(
                notificationsEverRequested: notificationsRequested))
        if let data = await artworkLoader.artworkData(
            primaryURL: product.imageURL, pageURL: url) {
            tracker.imageFileName = writeArtwork(data, for: item.id, store: store)
        }
        // BLOCKING, and part of creating the save rather than a job that runs
        // later: the tracker reaches disk already carrying every price Luna has
        // observed for this product (`claudedocs/price-tracking.md`'s "Product
        // snapshots"). One indexed read of a local file.
        ProductTrackerMerge.seedHistoryFromSnapshots(
            into: &tracker, candidate: product, candidateURL: url, store: snapshotStore)
        store.savePriceTracker(tracker, for: item.id)

        // The alternative-seller fan-out, on the NEW-tracker path only (a merge
        // has already been compared once, and re-running would just re-find the
        // stores it is excluding). It starts here and finishes in the
        // background, so the user's save does not wait on half a minute of
        // other people's web servers. The card appears now with the one
        // seller they were looking at, carries a "checking for other
        // sellers" row while the run is out, and grows as the sellers land.
        comparisonStarter.startComparison(itemID: item.id, sourceURL: url, store: store)

        PriceTrackerSaveAnnouncement.post(
            itemID: item.id, source: item.effectiveCaptureSource,
            isMerge: false, highlightedURL: nil)
        finishSeeding(itemID: item.id)
    }

    /// Regenerates the compact history index (Feature 3's data source) and
    /// kicks an immediate single-tracker refresh so a product seeded from
    /// history — or merged into an existing one — shows a LIVE price right
    /// away rather than waiting for the next background cycle. Fire-and-forget,
    /// wrapped in a background task: Feature 2's bounce-back may background the
    /// app immediately after this call returns.
    private func finishSeeding(itemID: UUID) {
        indexRegenerator.regenerate()
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "ProductSnapshotSeedRefresh"
        ) {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        guard backgroundTaskID != .invalid else { return }
        // The expiration handler above still needs the mutable `var`; the task
        // takes an immutable copy, because `UIApplication` is main-actor
        // isolated and this class is not — the end call has to hop.
        let taskID = backgroundTaskID
        Task {
            // Regenerates the index again on completion (`refreshTracker`
            // does this itself in production) — a live price is exactly the
            // kind of change the history pill's data should reflect right away.
            _ = await refresher.refresh(itemID: itemID)
            await MainActor.run { UIApplication.shared.endBackgroundTask(taskID) }
        }
    }

    private func writeArtwork(_ data: Data, for itemID: UUID, store: SavesStore) -> String? {
        let fileName = "\(itemID.uuidString)-product.jpg"
        let destination = store.articlesDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: destination, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

}

/// Renders a tracker's price history graph to a JPEG for inline email embedding —
/// the product-handling apps' `KindWiring` installs this behind
/// `EmailShareCenter.priceGraphSnapshot` (LunaSaves must not depend on
/// LunaPriceUI's graph view).
public enum PriceGraphEmailSnapshot {
    @MainActor
    public static func jpegData(for tracker: PriceTracker) -> Data? {
        let series = PriceHistory.series(for: tracker)
        guard series.count >= 2 else { return nil }
        let view = PriceGraphView(frame: CGRect(x: 0, y: 0, width: 600, height: 300))
        // The graph labels itself with `LunaColors`, which is light-on-dark in
        // both appearances — so the emailed sheet is the app's own night sky, not
        // white, or the text renders invisible.
        // `LunaSkyTrait` defaults to `.night`, so the plain dark trait collection
        // resolves the whole graph — background and labels — to true black.
        let night = UITraitCollection(userInterfaceStyle: .dark)
        view.backgroundColor = LunaColors.background.resolvedColor(with: night)
        view.setData(series, currency: tracker.displayCurrency)
        view.layoutIfNeeded()
        let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
        let image = renderer.image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        return image.jpegData(compressionQuality: 0.85)
    }
}
