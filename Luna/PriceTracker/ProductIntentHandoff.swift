//
//  ProductIntentHandoff.swift
//  Luna
//
//  The product-kind body of the Action Button intents' comparison summary —
//  compiled only into product-handling app targets (Price Tracker + the central
//  Luna app; excluded from the others via the synchronized group's membership
//  exceptions). Their `KindWiring` variants call `install()`, which fills
//  `ActionButtonIntentSupport.productComparisonDocument`; in article/media-only
//  apps the seam stays nil and the intents never look for a comparison, exactly
//  as `MediaIntentHandoff` works for downloads.
//

import Foundation
import LunaModels
import LunaPriceUI
import LunaStorage

enum ProductIntentHandoff {

    /// How old a seller's price may be and still be printed as "the price".
    ///
    /// The background cycle runs every 12 h, so a tracker that has been refreshed
    /// at all is inside this — the case this exists for is the one where the
    /// comparison document is the FIRST thing to look at a tracker in days, and
    /// a summary whose whole purpose is "where is this cheapest right now"
    /// cannot answer with last week's prices.
    static let freshnessInterval: TimeInterval = 24 * 60 * 60

    static func install() {
        ActionButtonIntentSupport.productComparisonDocument = { urlString in
            await document(forURLString: urlString)
        }
    }

    /// Test seam: the refresh a stale tracker gets before it is rendered.
    static var refreshRunner: (UUID) async -> Void = {
        _ = await PriceRefreshCoordinator.shared.refreshTracker(itemID: $0)
    }

    /// The comparison document for whichever tracker holds `urlString`, or nil
    /// when that URL is not a tracked product — the ordinary answer for every
    /// article, post and video the intents save.
    static func document(forURLString urlString: String) async -> URL? {
        let store = ReadingListStore.shared
        guard let match = store.priceTracker(containingStoreURL: urlString) else { return nil }
        // The ONE surface that still WAITS for the fan-out, because its whole
        // answer is a comparison between the sellers it finds. Everywhere else
        // the run is out in the background; here we join it (or start it) and
        // let it finish. `SellerComparison.complete` is a rendezvous, so an
        // extension's run already in flight is awaited rather than duplicated —
        // and it clears the pending marker either way, so the launch and refresh
        // sweeps do not run it again.
        if match.tracker.pendingComparison != nil {
            _ = await SellerComparison.complete(itemID: match.itemID, store: store)
        }
        guard let refreshed = store.item(withID: match.itemID)?.priceTracker else { return nil }
        if isStale(refreshed) {
            await refreshRunner(match.itemID)
        }
        guard let tracker = store.item(withID: match.itemID)?.priceTracker else { return nil }
        return await SellerComparisonDocument.write(
            for: tracker, articlesDirectory: store.articlesDirectory)
    }

    /// Stale when ANY seller is: the whole document is a comparison BETWEEN
    /// sellers, so one row a week out of date doesn't just misreport that row,
    /// it can hand the "Lowest" badge to the wrong shop.
    static func isStale(_ tracker: PriceTracker, now: Date = Date()) -> Bool {
        tracker.stores.contains { store in
            guard let refreshed = store.lastRefreshed else { return true }
            return now.timeIntervalSince(refreshed) > freshnessInterval
        }
    }
}
