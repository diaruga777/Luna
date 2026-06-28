//
//  PriceTrackerTests.swift
//  ClipTests
//

import ClipStorage
import ClipModels
import XCTest
@testable import Clip

/// Coverage for the `PriceTracker` model: best-price/alert math, threshold
/// formatting, store invariants, Codable migration safety, and the store's
/// stalest-first refresh ordering.
final class PriceTrackerTests: XCTestCase {

    private func makeTracker(price: String = "100.00", currency: String = "USD",
                             threshold: Double = 0.10) -> PriceTracker {
        PriceTracker(
            productName: "Widget",
            firstStoreURL: "https://a.example/p",
            price: Decimal(string: price)!,
            currency: currency,
            alertThresholdFraction: threshold,
            now: Date(timeIntervalSince1970: 1000))
    }

    // MARK: - Best price

    func testCurrentBestPriceIsMinimumAcrossStores() {
        var tracker = makeTracker(price: "100")
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://b.example/p", lastPrice: Decimal(string: "85"), currency: "USD"))
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://c.example/p", lastPrice: Decimal(string: "92"), currency: "USD"))
        XCTAssertEqual(tracker.currentBestPrice, Decimal(string: "85"))
    }

    func testCurrentBestPriceFallsBackToInitialWhenNoFetchedPrice() {
        var tracker = makeTracker(price: "50")
        // Add an unrefreshed store (no price).
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://b.example/p", lastPrice: nil, currency: "USD"))
        XCTAssertEqual(tracker.currentBestPrice, Decimal(string: "50"))
    }

    // MARK: - Best-price row (catch-up card highlight)

    func testBestPriceStoreIDPicksTheLowestFetchedPrice() {
        var tracker = makeTracker(price: "100")  // first store @ 100
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://b.example/p", lastPrice: Decimal(string: "85"), currency: "USD"))
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://c.example/p", lastPrice: Decimal(string: "92"), currency: "USD"))
        XCTAssertEqual(tracker.bestPriceStoreID, "https://b.example/p")
    }

    func testBestPriceStoreIDIsNilWhenNoStoreHasFetchedPrice() {
        // A tracker whose only store carries no fetched price has nothing to highlight.
        var tracker = makeTracker(price: "30")
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://a.example/p", lastPrice: nil, currency: "USD"))
        XCTAssertNil(tracker.bestPriceStoreID)
    }

    func testBestPriceStoreIDBreaksTiesByFirstStoreOrder() {
        var tracker = makeTracker(price: "60")  // first store @ 60
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://b.example/p", lastPrice: Decimal(string: "60"), currency: "USD"))
        // Tie at 60 → the first store in order wins (deterministic highlight).
        XCTAssertEqual(tracker.bestPriceStoreID, "https://a.example/p")
    }

    // MARK: - Discount + alert

    func testDiscountFractionAndAlerting() {
        var tracker = makeTracker(price: "100", threshold: 0.10)
        XCTAssertEqual(tracker.discountFraction, 0, accuracy: 0.0001)
        XCTAssertFalse(tracker.isAlerting)

        tracker.setPrice(Decimal(string: "80"), currency: "USD",
                         urlString: "https://a.example/p", at: Date())
        XCTAssertEqual(tracker.discountFraction, 0.20, accuracy: 0.0001)
        XCTAssertTrue(tracker.isAlerting)
    }

    func testAlertingRequiresMeetingThreshold() {
        var tracker = makeTracker(price: "100", threshold: 0.25)
        tracker.setPrice(Decimal(string: "80"), currency: "USD",
                         urlString: "https://a.example/p", at: Date())
        XCTAssertFalse(tracker.isAlerting, "20% drop must not alert with a 25% threshold")
        tracker.setPrice(Decimal(string: "75"), currency: "USD",
                         urlString: "https://a.example/p", at: Date())
        XCTAssertTrue(tracker.isAlerting, "exactly 25% drop alerts")
    }

    func testArchivedTrackerNeverAlerts() {
        var tracker = makeTracker(price: "100")
        tracker.setPrice(Decimal(string: "10"), currency: "USD",
                         urlString: "https://a.example/p", at: Date())
        tracker.isArchived = true
        XCTAssertFalse(tracker.isAlerting)
    }

    func testThresholdAbsoluteDrop() {
        let tracker = makeTracker(price: "200", threshold: 0.15)
        XCTAssertEqual(tracker.thresholdAbsoluteDrop, Decimal(string: "30"))
    }

    // MARK: - Alert viewed transition

    func testFreshTrackerHasNoUnviewedAlert() {
        let tracker = makeTracker(price: "100")
        XCTAssertFalse(tracker.isAlerting)
        XCTAssertFalse(tracker.hasUnviewedAlert)
    }

    func testAlertingTrackerHasUnviewedAlertUntilViewed() {
        var tracker = makeTracker(price: "100", threshold: 0.10)
        tracker.setPrice(Decimal(string: "70"), currency: "USD",
                         urlString: "https://a.example/p", at: Date())
        XCTAssertTrue(tracker.isAlerting)
        XCTAssertTrue(tracker.hasUnviewedAlert, "a fresh drop is unviewed")

        tracker.markAlertViewed(at: Date(timeIntervalSince1970: 2000))
        XCTAssertTrue(tracker.isAlerting, "still alerting — only the view state changed")
        XCTAssertFalse(tracker.hasUnviewedAlert, "viewing acknowledges the alert")
    }

    func testMarkAlertViewedNoOpsWhenNotAlerting() {
        var tracker = makeTracker(price: "100")
        tracker.markAlertViewed()
        XCTAssertNil(tracker.alertAcknowledgedAt, "nothing to acknowledge when not alerting")
    }

    func testFurtherDropClearsAcknowledgementSoAlertReFloats() {
        var tracker = makeTracker(price: "100", threshold: 0.10)
        tracker.setPrice(Decimal(string: "70"), currency: "USD",
                         urlString: "https://a.example/p", at: Date())
        tracker.markAlertViewed()
        XCTAssertFalse(tracker.hasUnviewedAlert)

        // A genuinely deeper drop re-opens the alert as unviewed.
        tracker.setPrice(Decimal(string: "50"), currency: "USD",
                         urlString: "https://a.example/p", at: Date())
        XCTAssertTrue(tracker.hasUnviewedAlert, "a fresh lower price re-floats the alert")
    }

    func testAcknowledgedAlertSurvivesCodableRoundTrip() throws {
        var tracker = makeTracker(price: "100", threshold: 0.10)
        tracker.setPrice(Decimal(string: "60"), currency: "USD",
                         urlString: "https://a.example/p", at: Date())
        tracker.markAlertViewed(at: Date(timeIntervalSince1970: 3000))
        let decoded = try JSONDecoder().decode(
            PriceTracker.self, from: JSONEncoder().encode(tracker))
        XCTAssertEqual(decoded.alertAcknowledgedAt, tracker.alertAcknowledgedAt)
        XCTAssertFalse(decoded.hasUnviewedAlert)
    }

    func testOldPayloadDecodesAsUnviewedAlert() throws {
        // A payload from before the alertAcknowledgedAt key → nil → unviewed.
        let json = #"{"productName":"X","initialPrice":100,"initialCurrency":"USD","stores":[{"urlString":"https://a.example/p","lastPrice":50,"currency":"USD"}]}"#
        let tracker = try JSONDecoder().decode(PriceTracker.self, from: Data(json.utf8))
        XCTAssertNil(tracker.alertAcknowledgedAt)
        XCTAssertTrue(tracker.isAlerting)
        XCTAssertTrue(tracker.hasUnviewedAlert)
    }

    // MARK: - Store invariants

    func testRemoveStoreKeepsAtLeastOne() {
        var tracker = makeTracker()
        XCTAssertFalse(tracker.removeStore(urlString: "https://a.example/p"),
                       "cannot remove the last store")
        XCTAssertEqual(tracker.stores.count, 1)

        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://b.example/p", lastPrice: Decimal(string: "90"), currency: "USD"))
        XCTAssertTrue(tracker.removeStore(urlString: "https://a.example/p"))
        XCTAssertEqual(tracker.stores.map(\.urlString), ["https://b.example/p"])
    }

    func testUpsertReplacesExistingStore() {
        var tracker = makeTracker(price: "100")
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://a.example/p", lastPrice: Decimal(string: "70"), currency: "USD"))
        XCTAssertEqual(tracker.stores.count, 1)
        XCTAssertEqual(tracker.currentBestPrice, Decimal(string: "70"))
    }

    /// Merge-revert: removing exactly the just-added seller from a multi-seller
    /// tracker leaves the pre-existing sellers intact (the "Read instead" merge case).
    func testRevertingAddedSellerLeavesTheRestIntact() {
        var tracker = makeTracker()
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://b.example/p", lastPrice: Decimal(string: "90"), currency: "USD"))
        let addedURL = "https://c.example/p"
        tracker.upsertStore(PriceTrackerStore(
            urlString: addedURL, lastPrice: Decimal(string: "80"), currency: "USD"))
        XCTAssertEqual(tracker.stores.count, 3)

        XCTAssertTrue(tracker.removeStore(urlString: addedURL),
                      "the just-added seller should be removable")
        XCTAssertFalse(tracker.hasStore(urlString: addedURL),
                       "the reverted seller is gone")
        XCTAssertEqual(tracker.stores.map(\.urlString),
                       ["https://a.example/p", "https://b.example/p"],
                       "the pre-existing sellers remain, in order")
    }

    /// Add-seller dedupe: `hasStore` is the guard the editor uses to reject a URL
    /// that is already a seller (no duplicate row, no redundant price fetch).
    func testHasStoreDetectsDuplicateSeller() {
        var tracker = makeTracker()
        XCTAssertTrue(tracker.hasStore(urlString: "https://a.example/p"))
        XCTAssertFalse(tracker.hasStore(urlString: "https://new.example/p"))
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://new.example/p", lastPrice: Decimal(string: "50"), currency: "USD"))
        XCTAssertTrue(tracker.hasStore(urlString: "https://new.example/p"))
        // Upserting the same URL again does not create a second row.
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://new.example/p", lastPrice: Decimal(string: "40"), currency: "USD"))
        XCTAssertEqual(tracker.stores.filter { $0.urlString == "https://new.example/p" }.count, 1)
    }

    func testMergingCheaperStoreDoesNotLowerBaseline() {
        var tracker = makeTracker(price: "100")
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://b.example/p", lastPrice: Decimal(string: "60"), currency: "USD"))
        XCTAssertEqual(tracker.initialPrice, Decimal(string: "100"))
        XCTAssertEqual(tracker.discountFraction, 0.40, accuracy: 0.0001)
    }

    // MARK: - Codable migration safety

    func testDecodesMinimalPayloadAndRepairsEmptyStores() throws {
        let json = #"{"productName":"X","initialPrice":42,"initialCurrency":"GBP"}"#
        let tracker = try JSONDecoder().decode(PriceTracker.self, from: Data(json.utf8))
        XCTAssertEqual(tracker.stores.count, 1, "empty stores repaired to satisfy ≥1 invariant")
        XCTAssertEqual(tracker.initialPrice, Decimal(42))
        XCTAssertEqual(tracker.initialCurrency, "GBP")
        XCTAssertEqual(tracker.alertThresholdFraction, 0.10)
        XCTAssertFalse(tracker.isArchived)
    }

    func testRoundTripCodable() throws {
        var tracker = makeTracker(price: "129.99", currency: "EUR", threshold: 0.2)
        tracker.brand = "Acme"
        tracker.productID = "SKU-1"
        let data = try JSONEncoder().encode(tracker)
        let decoded = try JSONDecoder().decode(PriceTracker.self, from: data)
        XCTAssertEqual(decoded, tracker)
    }

    func testClampsOutOfRangeThreshold() throws {
        let json = #"{"productName":"X","initialPrice":10,"initialCurrency":"USD","alertThresholdFraction":5.0}"#
        let tracker = try JSONDecoder().decode(PriceTracker.self, from: Data(json.utf8))
        XCTAssertEqual(tracker.alertThresholdFraction, 0.95, accuracy: 0.0001)
    }

    // MARK: - Stalest-first ordering

    func testStalestRefreshUsesOldestStore() {
        var tracker = makeTracker()
        tracker.setPrice(Decimal(10), currency: "USD", urlString: "https://a.example/p",
                         at: Date(timeIntervalSince1970: 5000))
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://b.example/p", lastPrice: Decimal(9), currency: "USD",
            lastRefreshed: Date(timeIntervalSince1970: 2000)))
        XCTAssertEqual(ReadingListStore.stalestRefresh(tracker),
                       Date(timeIntervalSince1970: 2000))
    }

    func testStalestFirstOrdersTrackersAndExcludesArchived() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ReadingListStore(containerURL: dir)

        let fresh = store.add(urlString: "https://fresh.example/p")
        var freshTracker = makeTracker()
        freshTracker.setPrice(Decimal(1), currency: "USD", urlString: "https://a.example/p",
                              at: Date(timeIntervalSince1970: 9000))
        store.savePriceTracker(freshTracker, for: fresh.id)

        let stale = store.add(urlString: "https://stale.example/p")
        var staleTracker = makeTracker()
        staleTracker.setPrice(Decimal(1), currency: "USD", urlString: "https://a.example/p",
                              at: Date(timeIntervalSince1970: 100))
        store.savePriceTracker(staleTracker, for: stale.id)

        let archived = store.add(urlString: "https://archived.example/p")
        var archivedTracker = makeTracker()
        archivedTracker.isArchived = true
        store.savePriceTracker(archivedTracker, for: archived.id)

        let ordered = store.priceTrackersStalestFirst()
        XCTAssertEqual(ordered.map(\.urlString),
                       ["https://stale.example/p", "https://fresh.example/p"])
    }
}
