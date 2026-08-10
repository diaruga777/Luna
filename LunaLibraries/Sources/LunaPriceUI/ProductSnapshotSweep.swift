//
//  ProductSnapshotSweep.swift
//  LunaPriceUI
//

import Foundation
import LunaHTMLClassification
import LunaModels
import LunaStorage

/// Folds the Safari extension's passive product snapshots into the trackers
/// they belong to — the read-side leg the snapshot pipeline was missing.
///
/// Snapshots used to be consulted exactly once, at tracker CREATION (or merge)
/// time. A product already being tracked could be browsed in Safari every day
/// and every one of those visits was recorded and then never read: no past-day
/// point ever reached the graph, the history index never learned what the
/// extension had seen, and a re-save of the same URL took the URL-equality
/// dedup short-circuit in `ReadingListIngestor`, which never seeded at all.
///
/// The sweep runs where the pending-comparison sweep already runs — the product
/// apps' `appDidLaunch` and the head of every background refresh cycle — and
/// matches by PRODUCT CODE: each tracker is turned into a matching candidate
/// (its keyed identifiers, flattened id, brand and name) and handed to the SAME
/// `SnapshotMatcher` tiers a save-time seed uses. URL equality is one of those
/// tiers, never the requirement.
public enum ProductSnapshotSweep {

    /// Sweeps every non-archived tracker once, folding any matching snapshots
    /// into its per-store history. Returns how many trackers gained history.
    /// Regenerates the shared history index when anything changed, so the
    /// extension's pill answers see the new points without waiting for the
    /// next refresh.
    @discardableResult
    public static func run(
        store: ReadingListStore = .shared,
        snapshots: [ProductSnapshot] = ProductSnapshotStore.shared.load(),
        indexRegenerator: () -> Void = { PriceHistoryIndexWriter.regenerate() }
    ) -> Int {
        guard !snapshots.isEmpty else { return 0 }
        var updated = 0
        for item in store.items() {
            guard var tracker = item.priceTracker, !tracker.isArchived,
                  let candidateURL = tracker.stores.first.flatMap({ URL(string: $0.urlString) })
            else { continue }
            let before = tracker
            ProductTrackerMerge.seedHistoryFromSnapshots(
                into: &tracker, candidate: candidate(for: tracker),
                candidateURL: candidateURL, snapshots: snapshots)
            guard tracker != before else { continue }
            store.updatePriceTracker(tracker, for: item.id)
            updated += 1
        }
        if updated > 0 { indexRegenerator() }
        return updated
    }

    /// The tracker as a `SnapshotMatcher` candidate: the same identifier
    /// family a fresh save carries, read back off the persisted tracker.
    static func candidate(for tracker: PriceTracker) -> ProductInfo {
        ProductInfo(
            name: tracker.productName,
            priceAmount: tracker.currentBestPrice,
            priceCurrency: tracker.initialCurrency,
            imageURL: nil,
            brand: tracker.brand,
            productID: tracker.productID,
            identifiers: tracker.identifiers)
    }
}
