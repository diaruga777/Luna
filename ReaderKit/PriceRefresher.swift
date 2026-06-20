//
//  PriceRefresher.swift
//  Clip
//

import Foundation

/// The seam the price refresher persists through, so it can be unit-tested
/// against an in-memory fake instead of the App Group store.
protocol PriceTrackerPersisting: AnyObject {
    /// Non-archived trackers, stalest-first (oldest minimum `lastRefreshed`).
    func priceTrackersStalestFirst() -> [ReadingListItem]
    /// Persists an updated tracker payload for an item.
    func updatePriceTracker(_ tracker: PriceTracker, for itemID: UUID) -> ReadingListItem?
}

extension ReadingListStore: PriceTrackerPersisting {}

/// Outcome of refreshing one tracker.
struct PriceRefreshOutcome: Equatable {
    let itemID: UUID
    let productName: String
    /// Best price before this refresh.
    let previousBest: Decimal
    /// Best price after this refresh.
    let newBest: Decimal
    /// Whether the tracker is alerting AFTER the refresh.
    let isAlerting: Bool
    /// Whether the tracker crossed its threshold on THIS refresh (was not alerting
    /// before, is alerting now) — the trigger for a one-shot local notification.
    let newlyAlerting: Bool
    let displayCurrency: String
    /// The post-refresh discount fraction (for tie-breaking notifications).
    let discountFraction: Double
}

/// Re-fetches every non-archived price tracker's store URLs, updates their prices,
/// and reports which trackers newly crossed their alert threshold. Resumable:
/// processes trackers stalest-first so a killed run still advances the oldest
/// trackers, and persists each tracker as soon as it finishes (not in one batch).
///
/// Pure-ish: the fetcher, detector, and clock are injected, so the whole loop runs
/// deterministically in tests with no network and a fixed time.
struct PriceRefresher {
    private let store: PriceTrackerPersisting
    private let fetcher: HTMLFetching
    private let detector: ProductPageDetector
    private let now: () -> Date

    init(
        store: PriceTrackerPersisting,
        fetcher: HTMLFetching,
        detector: ProductPageDetector = ProductPageDetector(),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.fetcher = fetcher
        self.detector = detector
        self.now = now
    }

    /// Refreshes all due trackers, returning an outcome per tracker that was
    /// processed (in stalest-first order). A tracker whose every store fetch fails
    /// is still returned (prices unchanged) so the caller can see it ran.
    func refreshAll() async -> [PriceRefreshOutcome] {
        var outcomes: [PriceRefreshOutcome] = []
        for item in store.priceTrackersStalestFirst() {
            guard let tracker = item.priceTracker else { continue }
            if let outcome = await refresh(tracker, itemID: item.id) {
                outcomes.append(outcome)
            }
        }
        return outcomes
    }

    /// Refreshes one tracker: fetches each store, re-extracts its price, persists,
    /// and computes the outcome. Returns nil only if the item vanished mid-refresh.
    private func refresh(_ tracker: PriceTracker, itemID: UUID) async -> PriceRefreshOutcome? {
        let wasAlerting = tracker.isAlerting
        let previousBest = tracker.currentBestPrice
        var updated = tracker
        let timestamp = now()

        for storeListing in tracker.stores {
            guard let url = storeListing.url,
                  let html = try? await fetcher.fetchHTML(from: url),
                  let info = detector.detect(urlString: storeListing.urlString, html: html) else {
                // Stamp the attempt time even on failure so it doesn't monopolize
                // the stalest-first queue every run.
                updated.setPrice(storeListing.lastPrice, currency: nil,
                                 urlString: storeListing.urlString, at: timestamp)
                continue
            }
            updated.setPrice(info.priceAmount, currency: info.priceCurrency,
                             urlString: storeListing.urlString, at: timestamp)
        }

        guard let persisted = store.updatePriceTracker(updated, for: itemID),
              let finalTracker = persisted.priceTracker else { return nil }

        let isAlerting = finalTracker.isAlerting
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
