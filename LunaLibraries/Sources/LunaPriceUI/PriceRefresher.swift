//
//  PriceRefresher.swift
//  LunaPriceUI
//

import LunaStorage
import LunaIngest
import LunaHTMLClassification
import LunaModels
import Foundation

/// The seam the price refresher persists through, so it can be unit-tested
/// against an in-memory fake instead of the App Group store.
public protocol PriceTrackerPersisting: AnyObject {
    /// Non-archived trackers, stalest-first (oldest minimum `lastRefreshed`).
    func priceTrackersStalestFirst() -> [ReadingListItem]
    /// Persists an updated tracker payload for an item.
    func updatePriceTracker(_ tracker: PriceTracker, for itemID: UUID) -> ReadingListItem?
    /// Stamps the row's sort date to now. Every deck orders on
    /// `bumpDate ?? dateAdded`, so this is what resurfaces a product whose alert
    /// has just fired.
    func bump(_ itemID: UUID)
    /// Single-item lookup, for `PriceRefresher.refreshTracker(itemID:)` — a
    /// just-seeded tracker doesn't wait for the stalest-first cycle to be found.
    func item(withID itemID: UUID) -> ReadingListItem?
}

extension ReadingListStore: PriceTrackerPersisting {}

/// Outcome of refreshing one tracker.
public struct PriceRefreshOutcome: Equatable {
    public let itemID: UUID
    public let productName: String
    /// Best price before this refresh.
    public let previousBest: Decimal
    /// Best price after this refresh.
    public let newBest: Decimal
    /// Whether the tracker is alerting AFTER the refresh.
    public let isAlerting: Bool
    /// Whether the tracker crossed its threshold on THIS refresh (was not alerting
    /// before, is alerting now) — the trigger for a one-shot local notification.
    public let newlyAlerting: Bool
    public let displayCurrency: String
    /// The post-refresh discount fraction (for tie-breaking notifications).
    public let discountFraction: Double
}

/// Re-fetches every non-archived price tracker's store URLs, updates their prices,
/// and reports which trackers newly crossed their alert threshold. Resumable:
/// processes trackers stalest-first so a killed run still advances the oldest
/// trackers, and persists each tracker as soon as it finishes (not in one batch).
///
/// Uses the same `PriceFetching` as save-time (static → embedded JSON → WKWebView
/// render), so every refresh re-fetches the real current price even for sites whose
/// price only exists after client-side rendering.
///
/// Pure-ish: the price fetcher and clock are injected, so the whole loop runs
/// deterministically in tests with no network and a fixed time.
public struct PriceRefresher {
    private let store: PriceTrackerPersisting
    private let priceFetcher: PriceFetching
    private let now: () -> Date

    public init(
        store: PriceTrackerPersisting,
        priceFetcher: PriceFetching,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.priceFetcher = priceFetcher
        self.now = now
    }

    /// Refreshes all due trackers, returning an outcome per tracker that was
    /// processed (in stalest-first order). A tracker whose every store fetch fails
    /// is still returned (prices unchanged) so the caller can see it ran.
    public func refreshAll() async -> [PriceRefreshOutcome] {
        var outcomes: [PriceRefreshOutcome] = []
        for item in store.priceTrackersStalestFirst() {
            guard let tracker = item.priceTracker else { continue }
            if let outcome = await refreshTracker(tracker, itemID: item.id) {
                outcomes.append(outcome)
            }
        }
        return outcomes
    }

    /// Refreshes exactly ONE tracker by item id, outside the stalest-first
    /// cycle — used right after a save seeds a tracker's history from passive
    /// snapshots, so the new/merged tracker doesn't wait for the next
    /// background cycle to show a live price. Returns nil when the item has
    /// no tracker (vanished, or never had one).
    public func refreshTracker(itemID: UUID) async -> PriceRefreshOutcome? {
        guard let tracker = store.item(withID: itemID)?.priceTracker else { return nil }
        return await refreshTracker(tracker, itemID: itemID)
    }

    /// Refreshes one tracker: fetches each store, re-extracts its price, persists,
    /// and computes the outcome. Returns nil only if the item vanished mid-refresh.
    public func refreshTracker(_ tracker: PriceTracker, itemID: UUID) async -> PriceRefreshOutcome? {
        let wasAlerting = tracker.isAlerting
        let previousBest = tracker.currentBestPrice
        var updated = tracker
        let timestamp = now()

        for storeListing in tracker.stores {
            guard let price = await priceFetcher.fetchPrice(
                forURLString: storeListing.urlString, prefetchedHTML: nil) else {
                // Stamp the attempt time even on failure so it doesn't monopolize
                // the stalest-first queue every run.
                updated.setPrice(storeListing.lastPrice, currency: nil,
                                 urlString: storeListing.urlString, at: timestamp)
                continue
            }
            updated.setPrice(price.amount, currency: price.currency,
                             urlString: storeListing.urlString, at: timestamp)
            updated.recordPriceSample(price.amount, currency: price.currency,
                                      urlString: storeListing.urlString, at: timestamp)
        }

        guard let persisted = store.updatePriceTracker(updated, for: itemID),
              let finalTracker = persisted.priceTracker else { return nil }

        let isAlerting = finalTracker.isAlerting
        // An alert FIRING resurfaces the product: the deck sorts on
        // `bumpDate ?? dateAdded` and nothing else, so this is how a price drop
        // reaches the front instead of staying wherever the save happened to
        // sit. Only the transition bumps — a tracker that is still alerting on
        // the next refresh must not climb again every hour.
        if isAlerting && !wasAlerting { store.bump(itemID) }
        return PriceRefreshOutcome(
            itemID: itemID,
            productName: finalTracker.productName,
            previousBest: previousBest,
            newBest: finalTracker.currentBestPrice,
            isAlerting: isAlerting,
            newlyAlerting: isAlerting && !wasAlerting,
            displayCurrency: finalTracker.displayCurrency,
            discountFraction: finalTracker.discountFraction)
    }
}
