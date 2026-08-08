//
//  SellerComparisonTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import LunaPriceCompare
import LunaStorage
import XCTest
@testable import LunaPriceUI

/// The save-time half of the alternative-seller comparison
/// (`claudedocs/price-comparison.md`): what the fan-out is ASKED, what happens
/// to what it finds, and the ordering that keeps the median honest.
final class SellerComparisonTests: XCTestCase {

    private var tempDirectory: URL!
    private var store: ReadingListStore!
    private var ingestor: ProductTrackerIngestor!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SellerComparisonTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: tempDirectory)
        ingestor = ProductTrackerIngestor()
        ingestor.indexRegenerator = {}
        ingestor.snapshotProvider = { [] }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        SellerComparisonRunner.installed = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func tracker(
        price: String = "100", currency: String = "USD",
        urlString: String = "https://source.example/p/1",
        gtin: String? = "0012345678905"
    ) -> PriceTracker {
        PriceTracker(
            productName: "Acme Widget",
            firstStoreURL: urlString,
            price: Decimal(string: price)!,
            currency: currency,
            brand: "Acme",
            productID: gtin,
            identifiers: ProductIdentifiers(gtin: gtin, brand: "Acme"))
    }

    private func result(
        domain: String, price: String, currency: String = "USD",
        path: String = "/p/1", confidence: SellerMatchConfidence = .gtin
    ) -> ComparableSellerResult {
        ComparableSellerResult(
            sellerID: domain, sellerName: domain, domain: domain,
            url: URL(string: "https://\(domain)\(path)")!,
            price: Decimal(string: price)!, currency: currency,
            productName: "Acme Widget", identifiers: ProductIdentifiers(gtin: "0012345678905"),
            imageURL: nil, confidence: confidence, source: .directory)
    }

    // MARK: - The request

    /// The tracker's own stores are excluded, so a re-comparison never spends a
    /// candidate re-finding a seller that is already attached.
    func testRequestExcludesEveryStoreAlreadyOnTheTracker() {
        var subject = tracker()
        subject.upsertStore(PriceTrackerStore(
            urlString: "https://other.example/p/1", lastPrice: 90, currency: "USD"))
        let request = SellerComparison.request(
            for: subject, sourceURL: URL(string: "https://source.example/p/1")!)
        XCTAssertEqual(
            Set(request.excludedURLStrings),
            ["https://source.example/p/1", "https://other.example/p/1"])
    }

    /// A tracker saved before keyed identifiers existed still has a flattened
    /// `brand`; the request must carry it, or the name-similarity tier can never
    /// be brand-qualified and every name match is refused.
    func testRequestFallsBackToTheFlattenedBrand() {
        var subject = tracker(gtin: nil)
        subject.identifiers = ProductIdentifiers()
        let request = SellerComparison.request(
            for: subject, sourceURL: URL(string: "https://source.example/p/1")!)
        XCTAssertEqual(request.identifiers.brand, "Acme")
        XCTAssertEqual(request.productName, "Acme Widget")
    }

    // MARK: - Applying results

    func testEveryResultBecomesAStoreWithALivePriceAndARecordedSample() {
        var subject = tracker()
        let added = SellerComparison.apply(
            [result(domain: "a.example", price: "80"), result(domain: "b.example", price: "120")],
            to: &subject, at: Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(added, 2)
        XCTAssertEqual(subject.stores.count, 3)
        let attached = subject.stores.first { $0.urlString.contains("a.example") }
        XCTAssertEqual(attached?.lastPrice, 80)
        XCTAssertNotNil(attached?.lastRefreshed)
        XCTAssertEqual(attached?.priceHistory.count, 1)
    }

    /// The baseline is the MEDIAN across every priced store, not the cheapest —
    /// otherwise "we found somewhere cheaper" is indistinguishable from a price
    /// drop, and every later real drop reads as flat.
    func testTheBaselineBecomesTheMedianAcrossEveryStore() {
        var subject = tracker(price: "100")
        SellerComparison.apply(
            [result(domain: "a.example", price: "80"), result(domain: "b.example", price: "120")],
            to: &subject)
        XCTAssertEqual(subject.initialPrice, 100)
        XCTAssertEqual(subject.initialCurrency, "USD")
    }

    func testAnEvenNumberOfStoresAveragesTheMiddleTwo() {
        var subject = tracker(price: "100")
        SellerComparison.apply([result(domain: "a.example", price: "80")], to: &subject)
        XCTAssertEqual(subject.initialPrice, 90)
    }

    /// Seeding must not badge the row. The cheapest of a dozen sellers being
    /// below the threshold is a fact about the market at the moment of saving,
    /// not a drop the user asked to hear about.
    func testSeedingNeverLeavesAnUnviewedAlert() {
        var subject = tracker(price: "100")
        subject.setAlertThresholdFraction(0.10)
        SellerComparison.apply(
            [result(domain: "a.example", price: "50"), result(domain: "b.example", price: "60")],
            to: &subject)
        XCTAssertTrue(subject.isAlerting, "the cheapest seller really is below the threshold")
        XCTAssertFalse(subject.hasUnviewedAlert, "but that must not badge the row at save time")
    }

    /// Two rows for the same shop is the one thing the store list must never
    /// show — and the engine's own per-domain key cannot know what the tracker
    /// already holds.
    func testASellerOnAHostTheTrackerAlreadyHoldsIsRefused() {
        var subject = tracker(urlString: "https://www.shop.example/p/1")
        let added = SellerComparison.apply(
            [result(domain: "shop.example", price: "80", path: "/p/2")], to: &subject)
        XCTAssertEqual(added, 0)
        XCTAssertEqual(subject.stores.count, 1)
    }

    func testNothingFoundLeavesTheBaselineExactlyWhereTheSaveLeftIt() {
        var subject = tracker(price: "100")
        let before = subject.alertAcknowledgedAt
        XCTAssertEqual(SellerComparison.apply([], to: &subject), 0)
        XCTAssertEqual(subject.initialPrice, 100)
        XCTAssertEqual(subject.alertAcknowledgedAt, before)
    }

    /// A foreign-currency seller is attached (it is a real place to buy the
    /// thing) but cannot enter the median — there is no FX source, so it would
    /// contribute a meaningless number.
    func testAForeignCurrencySellerIsAttachedButDoesNotMoveTheMedian() {
        var subject = tracker(price: "100", currency: "USD")
        SellerComparison.apply(
            [result(domain: "a.example", price: "1", currency: "GBP"),
             result(domain: "b.example", price: "140", currency: "USD")],
            to: &subject)
        XCTAssertEqual(subject.stores.count, 3)
        XCTAssertEqual(subject.initialPrice, 120, "median of the two USD stores")
    }

    // MARK: - Through the ingestor

    private func product() -> ProductInfo {
        ProductInfo(
            name: "Acme Widget", priceAmount: 100, priceCurrency: "USD",
            imageURL: nil, brand: "Acme", productID: "0012345678905",
            identifiers: ProductIdentifiers(gtin: "0012345678905", brand: "Acme"))
    }

    func testANewTrackerIsComparedAndSeeded() async {
        let item = store.add(urlString: "https://source.example/p/1")
        var seen: [String] = []
        ingestor.comparisonRunner = { itemID, url, store in
            seen.append(url.absoluteString)
            guard var tracker = store.item(withID: itemID)?.priceTracker else { return 0 }
            let added = SellerComparison.apply(
                [ComparableSellerResult(
                    sellerID: "a", sellerName: "A", domain: "a.example",
                    url: URL(string: "https://a.example/p/1")!, price: 80, currency: "USD",
                    productName: "Acme Widget", identifiers: ProductIdentifiers(),
                    imageURL: nil, confidence: .gtin, source: .directory)],
                to: &tracker)
            store.updatePriceTracker(tracker, for: itemID)
            return added
        }
        ingestor.refreshRunner = { _ in nil }

        await ingestor.ingest(
            item, url: URL(string: "https://source.example/p/1")!,
            product: product(), store: store)

        XCTAssertEqual(seen, ["https://source.example/p/1"])
        let saved = store.item(withID: item.id)?.priceTracker
        XCTAssertEqual(saved?.stores.count, 2)
        XCTAssertEqual(saved?.initialPrice, 90, "median of 100 and 80")
    }

    /// The merge path is deliberately NOT compared: that tracker has been
    /// through a fan-out once already, and re-running it would spend a dozen
    /// candidates re-finding the stores it is excluding.
    func testMergingIntoAnExistingTrackerRunsNoComparison() async {
        let existing = store.add(urlString: "https://source.example/p/1")
        store.savePriceTracker(
            PriceTracker(
                productName: "Acme Widget", firstStoreURL: "https://source.example/p/1",
                price: 100, currency: "USD", brand: "Acme", productID: "0012345678905"),
            for: existing.id)
        let incoming = store.add(urlString: "https://source.example/p/1?ref=x")
        var ran = false
        ingestor.comparisonRunner = { _, _, _ in ran = true; return 0 }
        ingestor.refreshRunner = { _ in nil }

        await ingestor.ingest(
            incoming, url: URL(string: "https://source.example/p/1?ref=x")!,
            product: product(), store: store)

        XCTAssertFalse(ran)
    }

    /// No runner installed (an app that doesn't compose the product kind, or a
    /// process that hasn't) must be indistinguishable from a comparison that
    /// found nothing — the save still lands, unchanged.
    func testWithNoRunnerInstalledNothingIsAttachedAndNothingFails() async {
        SellerComparisonRunner.installed = nil
        let item = store.add(urlString: "https://source.example/p/1")
        let added = await SellerComparison.runAndAttach(
            itemID: item.id, sourceURL: URL(string: "https://source.example/p/1")!, store: store)
        XCTAssertEqual(added, 0)
    }

    func testAnInstalledRunnerAttachesWhatItFinds() async {
        let item = store.add(urlString: "https://source.example/p/1")
        store.savePriceTracker(tracker(), for: item.id)
        SellerComparisonRunner.installed = { _ in
            SellerFanOutOutcome(
                results: [self.result(domain: "a.example", price: "80")],
                attemptedSellerIDs: ["a"], stopReason: .reachedTarget)
        }
        let added = await SellerComparison.runAndAttach(
            itemID: item.id, sourceURL: URL(string: "https://source.example/p/1")!, store: store)
        XCTAssertEqual(added, 1)
        XCTAssertEqual(store.item(withID: item.id)?.priceTracker?.stores.count, 2)
    }
}
