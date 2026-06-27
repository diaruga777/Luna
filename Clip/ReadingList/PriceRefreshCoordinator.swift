//
//  PriceRefreshCoordinator.swift
//  Clip
//

import ClipModels
import Foundation

/// Drives a background price refresh and surfaces the results: runs the pure
/// `PriceRefresher` over the shared store, then posts a local notification for
/// each tracker that first dropped past its threshold on this run.
///
/// The refresh logic itself lives in the dep-free `PriceRefresher`; this thin
/// main-app coordinator owns only the side effects (notifications, logging).
final class PriceRefreshCoordinator {
    static let shared = PriceRefreshCoordinator()

    private let refresher: PriceRefresher

    init(refresher: PriceRefresher = PriceRefresher(
        store: ReadingListStore.shared, priceFetcher: PriceFetcher())) {
        self.refresher = refresher
    }

    /// Refreshes all non-archived trackers and notifies on first threshold crossings.
    @discardableResult
    func refreshAndNotify() async -> [PriceRefreshOutcome] {
        DiagnosticLog.shared.record("price refresh: runner started", category: "price")
        let outcomes = await refresher.refreshAll()
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
        DiagnosticLog.shared.record("price refresh: runner completed", category: "price")
        return outcomes
    }
}
