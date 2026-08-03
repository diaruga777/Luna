//
//  ProductTrackerIngestor.swift
//  LunaPriceUI
//

import LunaDesignSystem
import LunaFetch
import LunaHTMLClassification
import LunaModels
import LunaSocial
import LunaStorage
import UIKit

/// Product-kind ingestion, extracted from `ReadingListIngestor` so only
/// product-handling apps carry the tracker-matching and price machinery. The
/// app shell installs this behind `IngestorKindHandlers.product` (via a thin
/// adapter in its `KindWiring` variant).
public final class ProductTrackerIngestor {
    public static let shared = ProductTrackerIngestor()

    public init() {}

    /// Turns a detected product page into a price tracker. Intelligent matching:
    /// if the product matches an existing tracker (by product id, else fuzzy
    /// name+brand), the new URL is MERGED into that tracker; otherwise a new
    /// tracker is created on this item.
    public func ingest(
        _ item: ReadingListItem, url: URL, product: ProductInfo, store: ReadingListStore
    ) async {
        // Try to merge into an existing tracker for the same product.
        let existing: [(id: UUID, tracker: PriceTracker)] = store.items().compactMap {
            guard let tracker = $0.priceTracker, $0.id != item.id else { return nil }
            return ($0.id, tracker)
        }
        if let matchID = ProductMatcher.bestMatch(for: product, among: existing),
           var matched = store.item(withID: matchID)?.priceTracker {
            let stores = product.trackerStores(fallbackURL: url)
            let newStores = stores.filter { !matched.hasStore(urlString: $0.urlString) }
            guard !newStores.isEmpty else {
                store.delete(item)
                PriceTrackerSaveAnnouncement.post(
                    itemID: matchID, source: item.effectiveCaptureSource,
                    isMerge: true, highlightedURL: stores.first?.urlString)
                return
            }
            for storeListing in newStores {
                matched.upsertStore(storeListing)
            }
            store.updatePriceTracker(matched, for: matchID)
            // The just-saved item was a duplicate route into an existing tracker;
            // drop its placeholder item so only the merged tracker remains.
            store.delete(item)
            PriceTrackerSaveAnnouncement.post(
                itemID: matchID, source: item.effectiveCaptureSource,
                isMerge: true, highlightedURL: newStores.first?.urlString)
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
            alertThresholdFraction: PriceAlertThresholdPolicy.initialThresholdFraction(
                notificationsEverRequested: notificationsRequested))
        if let imageURL = product.imageURL,
           let data = await downloadProductImage(imageURL) {
            let fileName = "\(item.id.uuidString)-product.jpg"
            try? data.write(
                to: store.articlesDirectory.appendingPathComponent(fileName), options: .atomic)
            tracker.imageFileName = fileName
        }
        store.savePriceTracker(tracker, for: item.id)

        PriceTrackerSaveAnnouncement.post(
            itemID: item.id, source: item.effectiveCaptureSource,
            isMerge: false, highlightedURL: nil)
    }

    /// Downloads a product image. Returns nil on any failure.
    private func downloadProductImage(_ imageURL: URL) async -> Data? {
        var request = URLRequest(url: imageURL, timeoutInterval: 8)
        request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count > 512, data.count <= 5 * 1024 * 1024
        else { return nil }
        return data
    }
}

/// Renders a tracker's price history graph to a JPEG for inline email embedding —
/// the product-handling apps' `KindWiring` installs this behind
/// `EmailShareCenter.priceGraphSnapshot` (LunaReadingList must not depend on
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
