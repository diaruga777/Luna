//
//  ProductIntentHandoff.swift
//  Luna
//
//  The product-kind body of the Action Button intents' comparison summary.
//  Compiled only into product-handling app targets (Price Tracker and the
//  central Luna app), and excluded from the others through the synchronized
//  group's membership exceptions. Their `KindWiring` variants call
//  `install()`, which fills `ActionButtonIntentSupport.productComparison`. In
//  an article- or media-only app, the seam stays nil and the intents never
//  look for a comparison, the same pattern `MediaIntentHandoff` uses for
//  downloads.
//

import Foundation
import LunaModels
import LunaPriceUI
import LunaStorage

enum ProductIntentHandoff {

    /// How old a seller's price may be and still be printed as "the price".
    ///
    /// The background cycle runs every 12 hours, so a tracker that has been
    /// refreshed at all is inside this window. This exists for the case where
    /// the comparison document is the first thing to look at a tracker in
    /// days, and a summary whose whole purpose is "where is this cheapest
    /// right now" cannot answer with last week's prices.
    static let freshnessInterval: TimeInterval = 24 * 60 * 60

    static func install() {
        ActionButtonIntentSupport.productComparison = ProductComparisonLeg()
    }

    /// The installed product leg: the intents' one question over `document`.
    private struct ProductComparisonLeg: IntentProductComparisonProviding {
        func comparisonDocumentURL(forURLString urlString: String) async -> URL? {
            await ProductIntentHandoff.document(forURLString: urlString)
        }
    }

    /// The comparison document for whichever tracker holds `urlString`, or nil
    /// when that URL is not a tracked product — the ordinary answer for every
    /// article, post and video the intents save.
    static func document(forURLString urlString: String) async -> URL? {
        let store = SavesStore.shared
        guard let match = store.priceTracker(containingStoreURL: urlString) else { return nil }
        // The one surface that waits for the fan-out, because its whole
        // answer is a comparison between the sellers it finds. Everywhere else
        // the run happens in the background; here it joins or starts it and
        // waits for it to finish. `SellerComparison.complete` is a rendezvous,
        // so an extension's run already in flight is awaited rather than
        // duplicated, and it clears the pending marker either way, so the
        // launch and refresh sweeps do not run it again.
        if match.tracker.pendingComparison != nil {
            _ = await SellerComparison.complete(itemID: match.itemID, store: store)
        }
        guard let refreshed = store.item(withID: match.itemID)?.priceTracker else { return nil }
        if isStale(refreshed) {
            _ = await PriceRefreshCoordinator.shared.refreshTracker(itemID: match.itemID)
        }
        guard let tracker = store.item(withID: match.itemID)?.priceTracker else { return nil }
        return await SellerComparisonDocument.write(
            for: tracker, articlesDirectory: store.articlesDirectory)
    }

    /// Stale when any seller is: the whole document is a comparison between
    /// sellers, so one row a week out of date does not just misreport that
    /// row — it can hand the "Lowest" badge to the wrong shop.
    static func isStale(_ tracker: PriceTracker, now: Date = Date()) -> Bool {
        tracker.stores.contains { store in
            guard let refreshed = store.lastRefreshed else { return true }
            return now.timeIntervalSince(refreshed) > freshnessInterval
        }
    }
}
