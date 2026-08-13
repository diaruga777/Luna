//
//  PriceRefreshCoordinator.swift
//  Luna
//

import LunaSocial
import LunaStorage
import LunaModels
import Foundation

/// Drives a background price refresh and surfaces the results: runs the pure
/// `PriceRefresher` over the shared store, then posts a local notification for
/// each tracker that first dropped past its threshold on this run.
///
/// The refresh logic itself lives in the dep-free `PriceRefresher`; this thin
/// main-app coordinator owns only the side effects (notifications, logging).
public final class PriceRefreshCoordinator {
    public static let shared = PriceRefreshCoordinator()

    private let refresher: PriceRefresher

    public init(refresher: PriceRefresher = PriceRefresher(
        store: SavesStore.shared, priceFetcher: PriceFetcher())) {
        self.refresher = refresher
    }

    /// Refreshes all non-archived trackers and notifies on first threshold crossings.
    @discardableResult
    public func refreshAndNotify() async -> [PriceRefreshOutcome] {
        DiagnosticLog.shared.record("price refresh: runner started", category: "price")
        // No snapshot work happens here. Product snapshots are read exactly
        // once, synchronously, at the moment a tracker is CREATED — a refresh
        // cycle fetches live prices and has nothing to learn from a record of
        // what a page cost before the tracker existed.
        //
        // Finish any seller fan-out a dead process left mid-run, BEFORE the
        // refresh: the sellers it attaches are priced as it attaches them, so
        // running it first spares the refresh from re-fetching them, and the
        // baseline it settles is what this cycle's alert decisions are made
        // against. A refresh cycle is exactly the right moment — the app is
        // already awake with the network, on the same 12 h rhythm.
        let finished = await SellerComparison.completePending(store: SavesStore.shared)
        if finished > 0 {
            DiagnosticLog.shared.record(
                "price refresh: finished \(finished) pending seller comparison(s)",
                category: "price")
        }
        let outcomes = await refresher.refreshAll()
        notify(outcomes)
        // The history pill's data source: a refresh is exactly when a
        // tracker's priceHistory changes, so the index the extension reads
        // must be regenerated every cycle, not only at save time.
        PriceHistoryIndexWriter.regenerate()
        DiagnosticLog.shared.record("price refresh: runner completed", category: "price")
        return outcomes
    }

    /// Refreshes exactly ONE tracker (by saved item id) and notifies if
    /// it newly crosses its threshold — the same notification behavior as a
    /// background cycle, scoped to one tracker. Used right after
    /// `ProductTrackerIngestor` seeds a fresh/merged tracker's history from
    /// passive Safari snapshots, so the user doesn't wait for the next
    /// background cycle to see a live price.
    @discardableResult
    public func refreshTracker(itemID: UUID) async -> PriceRefreshOutcome? {
        guard let outcome = await refresher.refreshTracker(itemID: itemID) else { return nil }
        notify([outcome])
        PriceHistoryIndexWriter.regenerate()
        return outcome
    }

    private func notify(_ outcomes: [PriceRefreshOutcome]) {
        let dropped = outcomes.filter { $0.newlyAlerting }
        DiagnosticLog.shared.record(
            "price refresh: \(outcomes.count) trackers, \(dropped.count) newly alerting",
            category: "price")
        for outcome in dropped {
            NotificationManager.postPriceDrop(
                productName: outcome.productName,
                newPrice: PriceFormatting.string(
                    amount: outcome.newBest, currency: outcome.displayCurrency),
                discountPercent: Int((outcome.discountFraction * 100).rounded()))
        }
    }
}
