//
//  ProductTrackerMerge.swift
//  LunaPriceUI
//

import Foundation
import LunaHTMLClassification
import LunaModels
import LunaStorage

/// The merge-or-create decision for a freshly classified product page, shared
/// by every surface that can turn one into a tracker: the in-app new-tracker
/// path (`ProductTrackerIngestor.ingest`) and the extension's immediate-editor
/// path (`ExtensionProductPresenter.presentPriceEditor`).
///
/// Before this existed, only the in-app path consulted `ProductMatcher
/// .bestMatch` or seeded history from passive Safari snapshots — a share-sheet
/// save of a product already being tracked created a second, unrelated
/// tracker instead of merging into the first, even when both pages declared
/// the SAME GTIN. `mergeIfPossible` is what both callers now ask first.
public enum ProductTrackerMerge {

    public enum Outcome: Equatable {
        /// No existing tracker matched `product` — the caller should create a
        /// new one (each caller's own way: the app awaits an image download,
        /// the extension cannot afford to).
        case newTracker
        /// `product` matched the tracker at `itemID`. Its stores, identifiers
        /// and snapshot-seeded history have already been persisted; the
        /// caller only needs to remove ITS OWN placeholder item (the one this
        /// save was about to create/replace) and announce the merge.
        case merged(itemID: UUID, highlightedURLString: String?)
    }

    /// Merges `product` into its best-matching tracker (by `ProductMatcher
    /// .bestMatch`, excluding `excludingItemID` — the placeholder item this
    /// save is about to replace), unions its keyed identifiers in, seeds
    /// history from passive snapshots, and — when the target tracker has
    /// never been compared and holds fewer than two stores — starts a
    /// background seller comparison from `url` (Fix 8:
    /// `claudedocs/price-comparison.md`'s "re-saves of a seller-less tracker
    /// kick a comparison"). Returns `.newTracker` when nothing matched.
    @discardableResult
    public static func mergeIfPossible(
        product: ProductInfo, url: URL, excludingItemID: UUID, store: ReadingListStore,
        comparisonStarter: (UUID, URL, ReadingListStore) -> Void,
        snapshots: [ProductSnapshot] = ProductSnapshotStore.shared.load()
    ) -> Outcome {
        let existing: [(id: UUID, tracker: PriceTracker)] = store.items().compactMap {
            guard let tracker = $0.priceTracker, $0.id != excludingItemID else { return nil }
            return ($0.id, tracker)
        }
        guard let matchID = ProductMatcher.bestMatch(for: product, among: existing),
              var matched = store.item(withID: matchID)?.priceTracker
        else { return .newTracker }

        // Fix 8: read BEFORE this save's own store is added below. A tracker
        // that has never been through a fan-out and still has fewer than two
        // stores has effectively never been compared — the rule that "the
        // merge path is never compared" (claudedocs/price-comparison.md) was
        // written for a tracker that HAD already been through one, not for
        // one a prior save merely created and left alone. Reading the count
        // AFTER this save's own new store would make every ordinary merge
        // look "already at 2 stores" and never fire at all.
        let neverCompared = matched.pendingComparison == nil && matched.stores.count < 2

        let stores = product.trackerStores(fallbackURL: url)
        let newStores = stores.filter { !matched.hasStore(urlString: $0.urlString) }
        matched.identifiers = matched.identifiers.merging(
            product.identifiers.merging(ProductIdentifiers(brand: product.brand)))
        seedHistoryFromSnapshots(
            into: &matched, candidate: product, candidateURL: url, snapshots: snapshots)
        for storeListing in newStores { matched.upsertStore(storeListing) }
        store.updatePriceTracker(matched, for: matchID)

        if neverCompared {
            // A repeat save of the same seller-less product is the moment to
            // actually try — the comparison excludes every store the tracker
            // now holds (including the one just merged in), so it never
            // re-finds what this save already attached.
            comparisonStarter(matchID, url, store)
        }

        let highlighted = (newStores.first ?? stores.first)?.urlString
        return .merged(itemID: matchID, highlightedURLString: highlighted)
    }

    /// Matches passive Safari snapshots against the just-saved product
    /// (`SnapshotMatcher`) and folds any that match into the tracker's
    /// per-store history, grouped by host so a product never gets two stores
    /// for the same host. Snapshots are never deleted by matching — they
    /// remain available as history for other products and for the history
    /// pill.
    ///
    /// Moved here (from `ProductTrackerIngestor`) so the extension's
    /// immediate-editor path gets the same seeding a new tracker always did —
    /// a passive snapshot with an offer-level `gtin13` is exactly the kind of
    /// history a share-sheet save should fold in too.
    public static func seedHistoryFromSnapshots(
        into tracker: inout PriceTracker, candidate: ProductInfo, candidateURL: URL,
        snapshots: [ProductSnapshot] = ProductSnapshotStore.shared.load()
    ) {
        guard !snapshots.isEmpty else { return }
        // The tracker's market is its source page's currency. A snapshot of the
        // same product in another market (the same GTIN browsed on amazon.co.uk
        // against a USD tracker) is real data Luna cannot use: there is no FX
        // source, so folding it in would put a £ point on a $ graph and a
        // foreign store in the seller list.
        let marketCurrency = tracker.initialCurrency.uppercased()
        let comparable = snapshots.filter { $0.currency.uppercased() == marketCurrency }
        guard !comparable.isEmpty else { return }
        let matched = SnapshotMatcher.matchingSnapshots(
            for: candidate, candidateURL: candidateURL,
            existingStoreURLStrings: tracker.stores.map(\.urlString),
            among: comparable)
        guard !matched.isEmpty else { return }

        let byHost = Dictionary(grouping: matched) { $0.host.lowercased() }
        for (host, hostSnapshots) in byHost.sorted(by: { $0.key < $1.key }) {
            let samples: [(day: Date, price: Decimal, currency: String)] = hostSnapshots
                .sorted { $0.day < $1.day }
                .compactMap { snapshot in
                    guard let amount = snapshot.priceAmount,
                          let day = utcDayDate(fromDayString: snapshot.day)
                    else { return nil }
                    return (day, amount, snapshot.currency)
                }
            guard !samples.isEmpty else { continue }
            tracker.mergeHistorySamples(
                samples, forHost: host, newStoreURLString: hostSnapshots[0].url)
        }
    }

    /// Parses a `yyyy-MM-dd` UTC day string (the snapshot file's bucketing) to
    /// a `Date` at that day's UTC midnight.
    static func utcDayDate(fromDayString day: String) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.date(from: day)
    }
}
