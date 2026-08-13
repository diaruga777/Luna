//
//  ProductTrackerMerge.swift
//  LunaPriceUI
//

import Foundation
import LunaHTMLClassification
import LunaModels
import LunaPriceCompare
import LunaStorage

/// The merge-or-create decision for a freshly classified product page, shared
/// by every surface that can turn one into a tracker: the in-app new-tracker
/// path (`ProductTrackerIngestor.ingest`) and the extension's immediate-editor
/// path (`ExtensionProductPresenter.presentPriceEditor`).
///
/// `mergeIfPossible` is what both callers ask first, so a share-sheet save of
/// a product already being tracked merges into the existing tracker — via
/// `ProductMatcher.bestMatch` and the passive-snapshot history seed — instead
/// of creating a second, unrelated tracker for the same GTIN.
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
        product: ProductInfo, url: URL, excludingItemID: UUID, store: SavesStore,
        comparisonStarter: any SellerComparisonStarting,
        snapshotStore: ProductSnapshotStore = .shared
    ) -> Outcome {
        let existing: [(id: UUID, tracker: PriceTracker)] = store.items().compactMap {
            guard let tracker = $0.priceTracker, $0.id != excludingItemID else { return nil }
            return ($0.id, tracker)
        }
        guard let matchID = ProductMatcher.bestMatch(for: product, among: existing),
              var matched = store.item(withID: matchID)?.priceTracker
        else { return .newTracker }

        // Fix 8 (claudedocs/price-comparison.md): read this count BEFORE this
        // save's own store is added below. A tracker with no fan-out yet and
        // fewer than two stores has never really been compared, even though
        // "the merge path is never compared" was written for a tracker that
        // HAD been through one. Reading the count after this save's new store
        // is added would make every ordinary merge look already at 2 stores,
        // and the comparison would never fire.
        let neverCompared = matched.pendingComparison == nil && matched.stores.count < 2

        let stores = product.trackerStores(fallbackURL: url)
        let newStores = stores.filter { !matched.hasStore(urlString: $0.urlString) }
        matched.identifiers = matched.identifiers.merging(
            product.identifiers.merging(ProductIdentifiers(brand: product.brand)))
        // BEFORE seeding: an explicit re-save of a removed seller is the user
        // asking for that host back, so its observations are eligible again in
        // the same pass rather than one save later.
        for storeListing in newStores { matched.clearSellerRejection(urlString: storeListing.urlString) }
        seedHistoryFromSnapshots(
            into: &matched, candidate: product, candidateURL: url, store: snapshotStore)
        for storeListing in newStores { matched.upsertStore(storeListing) }
        store.updatePriceTracker(matched, for: matchID)

        if neverCompared {
            // A repeat save of the same seller-less product is the moment to
            // actually try — the comparison excludes every store the tracker
            // now holds (including the one just merged in), so it never
            // re-finds what this save already attached.
            comparisonStarter.startComparison(itemID: matchID, sourceURL: url, store: store)
        }

        let highlighted = (newStores.first ?? stores.first)?.urlString
        return .merged(itemID: matchID, highlightedURLString: highlighted)
    }

    /// Folds every stored observation of this product into the tracker's
    /// per-store history, grouped by host so a product never gets two stores
    /// for the same host. Snapshots are never deleted by matching — the same
    /// observation can seed a different product later, and remains available
    /// to the history pill.
    ///
    /// **This is a blocking local database read, and it belongs on the save
    /// path.** It is the whole of the read side: there is no background sweep
    /// and no deferred job. A tracker is created with the history Luna already
    /// has, or it is created with none — never with none and then quietly
    /// gaining some at the next launch. The read is by identifier through
    /// `ProductSnapshotStore`'s index, so it opens only the records that could
    /// match rather than decoding the whole store.
    public static func seedHistoryFromSnapshots(
        into tracker: inout PriceTracker, candidate: ProductInfo, candidateURL: URL,
        store snapshotStore: ProductSnapshotStore = .shared
    ) {
        let matches = snapshotStore.matchingSnapshots(
            for: candidate, candidateURL: candidateURL,
            existingStoreURLStrings: tracker.stores.map(\.urlString))
        seedHistory(into: &tracker, from: matches)
    }

    /// The pure half: fold already-matched observations into `tracker`.
    static func seedHistory(into tracker: inout PriceTracker, from matches: [ProductSnapshot]) {
        // The tracker's market is its source page's currency. An observation of
        // the same product in another market (the same GTIN browsed on
        // amazon.co.uk against a USD tracker) is real data Luna cannot use:
        // there is no FX source, so folding it in would put a £ point on a $
        // graph and a foreign store in the seller list.
        let marketCurrency = tracker.initialCurrency.uppercased()
        let matched = matches.filter { $0.currency.uppercased() == marketCurrency }
        guard !matched.isEmpty else { return }

        let byHost = Dictionary(grouping: matched) { $0.host.lowercased() }
        for (host, hostSnapshots) in byHost.sorted(by: { $0.key < $1.key }) {
            let samples: [(day: Date, price: Decimal, currency: String)] = hostSnapshots
                .sorted { $0.day < $1.day }
                .compactMap { snapshot in
                    guard let amount = snapshot.priceAmount,
                          // The INSTANT, not the UTC-midnight of the day
                          // string: the graph's buckets are local days
                          // (`PriceTrackerStore.mergeHistorySamples` uses
                          // `Calendar.current`), and UTC midnight resolves to
                          // the PREVIOUS local day for every user west of
                          // Greenwich — an observation dated a day before the
                          // one they made it on. `capturedAt` is the real
                          // moment; the day string stays the record's identity.
                          let day = snapshot.capturedInstant
                            ?? snapshot.day.startOfDayUTC
                    else { return nil }
                    return (day, amount, snapshot.currency)
                }
            guard !samples.isEmpty else { continue }
            tracker.mergeHistorySamples(
                samples, forHost: host, newStoreURLString: hostSnapshots[0].url)
        }
    }
}
