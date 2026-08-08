//
//  SellerComparison.swift
//  LunaPriceUI
//

import Foundation
import LunaModels
import LunaPriceCompare
import LunaStorage

/// The save-time comparison, as the surfaces use it: build the request from a
/// tracker, run the installed fan-out, attach what it found, and re-base the
/// alert baseline.
///
/// **The ORDER here is the whole point**, and it is not the obvious one. A
/// tracker is created from the SOURCE page alone and only then grown, because
/// `PriceTracker`'s multi-store initializer takes the CHEAPEST store's currency
/// as `initialCurrency` — build every seller up front and a single foreign-
/// currency listing that happens to be numerically lowest silently redenominates
/// the tracker, and the median computed against it is meaningless. So: save from
/// the source, `upsertStore` each verified seller, and seed the baseline last,
/// once every price is in.
public enum SellerComparison {

    /// The fan-out request for a tracker that has just been created from
    /// `sourceURL`. Every store already on the tracker is excluded, so a
    /// re-comparison never re-finds what it found last time.
    public static func request(
        for tracker: PriceTracker, sourceURL: URL, categoryHints: [String] = []
    ) -> SellerFanOutRequest {
        var identifiers = tracker.identifiers
        if identifiers.brand == nil { identifiers.brand = tracker.brand }
        return SellerFanOutRequest(
            sourceURL: sourceURL,
            productName: tracker.productName,
            identifiers: identifiers,
            categoryHints: categoryHints,
            excludedURLStrings: tracker.stores.map(\.urlString))
    }

    /// Attaches every verified alternative seller and re-bases the alert
    /// baseline onto the median. Returns how many stores were added.
    ///
    /// Each attached store gets BOTH a live price (`lastPrice`/`lastRefreshed`,
    /// so it reads as fetched-now rather than as passive history) and a recorded
    /// day sample, which is what makes today the first point of its graph.
    ///
    /// One store per retailer FAMILY: the engine already keys its own results by
    /// registrable domain, but the tracker may already hold a store on a host the
    /// engine had no reason to exclude (a redirect, a regional sibling), and two
    /// rows for the same shop is the one thing the store list must never show.
    @discardableResult
    public static func apply(
        _ results: [ComparableSellerResult], to tracker: inout PriceTracker,
        at date: Date = Date()
    ) -> Int {
        var claimedDomains = Set(
            tracker.stores.compactMap { store -> String? in
                guard let host = URL(string: store.urlString)?.host else { return nil }
                return ProductIdentityMatching.registrableDomain(host)
            })
        var added = 0
        for result in results {
            let urlString = result.url.absoluteString
            guard !tracker.hasStore(urlString: urlString),
                  claimedDomains.insert(result.domain).inserted
            else { continue }
            var store = PriceTrackerStore(
                urlString: urlString, lastPrice: result.price,
                currency: result.currency, lastRefreshed: date)
            store.recordSample(price: result.price, currency: result.currency, at: date)
            tracker.upsertStore(store)
            added += 1
        }
        guard added > 0 else { return 0 }
        tracker.seedComparisonBaseline(at: date)
        return added
    }

    /// The whole save-time leg for a tracker already persisted under `itemID`:
    /// run the fan-out, re-read the tracker (the editor or a refresh may have
    /// touched it while the network was out), attach, persist.
    ///
    /// Returns how many sellers were attached — 0 both when nothing was found
    /// and when no runner is installed, because neither is a failure the save
    /// should react to.
    @discardableResult
    public static func runAndAttach(
        itemID: UUID, sourceURL: URL, store: ReadingListStore,
        categoryHints: [String] = [], now: Date = Date()
    ) async -> Int {
        guard let tracker = store.item(withID: itemID)?.priceTracker else { return 0 }
        guard let outcome = await SellerComparisonRunner.run(
            request(for: tracker, sourceURL: sourceURL, categoryHints: categoryHints)),
              !outcome.results.isEmpty
        else { return 0 }
        guard var current = store.item(withID: itemID)?.priceTracker else { return 0 }
        let added = apply(outcome.results, to: &current, at: now)
        guard added > 0 else { return 0 }
        store.updatePriceTracker(current, for: itemID)
        return added
    }
}
