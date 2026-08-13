//
//  FreshComparablePricesTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import LunaPriceCompare
import LunaPriceUI
import XCTest

/// The rule behind the Safari alternative-seller pill: which stored or
/// just-fetched price may be shown as a CURRENT better price, and how a
/// fetched one gets written back into the passive snapshot store.
///
/// `LunaSafari/ComparableSellerFinder.swift` reads the App Group's index and
/// snapshot file and runs the constrained fan-out, but the DECISION it makes
/// with what it finds lives here in `LunaPriceCompare` so it can be executed
/// rather than only read as source text (the appex is not compiled into
/// LunaTests — see `SharedProductMatchingParityTests`).
final class FreshComparablePricesTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func point(
        seller: String = "Other Shop", domain: String = "other.example",
        url: String = "https://other.example/p/1",
        price: Decimal = 40, currency: String = "USD", ageHours: Double = 1
    ) -> ComparablePricePoint {
        ComparablePricePoint(
            sellerName: seller, domain: domain, urlString: url, price: price,
            currency: currency, capturedAt: now.addingTimeInterval(-ageHours * 3600))
    }

    private func lowest(
        _ points: [ComparablePricePoint], pagePrice: Decimal = 50,
        pageCurrency: String = "USD", pageDomain: String = "shop.example"
    ) -> ComparablePricePoint? {
        FreshComparablePrices.lowestCheaper(
            among: points, pagePrice: pagePrice, pageCurrency: pageCurrency,
            pageDomain: pageDomain, now: now)
    }

    // MARK: - The 24h freshness rule

    func testTheWindowIsTwentyFourHours() {
        XCTAssertEqual(FreshComparablePrices.freshnessWindow, 24 * 60 * 60)
    }

    func testAPriceFromAnHourAgoIsFresh() {
        XCTAssertTrue(FreshComparablePrices.isFresh(now.addingTimeInterval(-3600), now: now))
    }

    func testAPriceJustInsideTwentyFourHoursIsStillFresh() {
        XCTAssertTrue(FreshComparablePrices.isFresh(
            now.addingTimeInterval(-(24 * 3600 - 1)), now: now))
    }

    func testAPriceExactlyTwentyFourHoursOldIsStale() {
        XCTAssertFalse(FreshComparablePrices.isFresh(now.addingTimeInterval(-24 * 3600), now: now))
    }

    /// Clock skew between the app process and the appex must not throw an
    /// answer away — a future stamp is certainly not older than a day.
    func testAFutureTimestampCountsAsFresh() {
        XCTAssertTrue(FreshComparablePrices.isFresh(now.addingTimeInterval(600), now: now))
    }

    func testAStalePriceIsNeverTheAnswer() {
        XCTAssertNil(lowest([point(price: 10, ageHours: 30)]))
    }

    func testAFreshCheaperPriceIsTheAnswer() {
        XCTAssertEqual(lowest([point(price: 10, ageHours: 23)])?.price, 10)
    }

    // MARK: - What disqualifies a point

    func testADearerPriceIsRefused() {
        XCTAssertNil(lowest([point(price: 60)]))
    }

    func testTheSamePriceIsRefused() {
        XCTAssertNil(lowest([point(price: 50)]))
    }

    /// No FX source exists anywhere in Luna, so a cheaper NUMBER in another
    /// currency is not a cheaper price.
    func testAForeignCurrencyIsRefusedEvenWhenTheNumberIsLower() {
        XCTAssertNil(lowest([point(price: 30, currency: "GBP")]))
    }

    func testThePagesOwnRetailerIsNotAnAlternativeToItself() {
        XCTAssertNil(lowest([point(domain: "shop.example", url: "https://shop.example/p/2", price: 10)]))
    }

    func testAZeroPriceIsRefused() {
        XCTAssertNil(lowest([point(price: 0)]))
    }

    // MARK: - Choosing between several

    func testTheLowestFreshCheaperPriceWins() {
        let answer = lowest([
            point(seller: "A", domain: "a.example", price: 45),
            point(seller: "B", domain: "b.example", price: 30),
            point(seller: "C", domain: "c.example", price: 38),
        ])
        XCTAssertEqual(answer?.sellerName, "B")
    }

    func testAStaleCheaperPriceLosesToAFreshDearerOne() {
        let answer = lowest([
            point(seller: "Stale", domain: "a.example", price: 5, ageHours: 48),
            point(seller: "Fresh", domain: "b.example", price: 45, ageHours: 2),
        ])
        XCTAssertEqual(answer?.sellerName, "Fresh")
    }

    /// Same inputs, same seller — a tie that resolved by list order would make
    /// the pill flicker between two shops on consecutive page loads.
    func testATieBreaksOnTheDomainRatherThanListOrder() {
        let ascending = lowest([
            point(seller: "Zed", domain: "z.example", price: 30),
            point(seller: "Acme", domain: "a.example", price: 30),
        ])
        let descending = lowest([
            point(seller: "Acme", domain: "a.example", price: 30),
            point(seller: "Zed", domain: "z.example", price: 30),
        ])
        XCTAssertEqual(ascending?.sellerName, "Acme")
        XCTAssertEqual(descending?.sellerName, "Acme")
    }

    func testAnEmptyListAnswersNothing() {
        XCTAssertNil(lowest([]))
    }

    // MARK: - Writing a fetched result back as a snapshot

    private func result(
        seller: String = "Acme", domain: String = "acme.example",
        url: String = "https://acme.example/p/1", price: Decimal = 39.5,
        currency: String = "USD", name: String = "Widget 3000",
        identifiers: ProductIdentifiers = ProductIdentifiers(gtin: "0012345678905", brand: "Widgets")
    ) -> ComparableSellerResult {
        ComparableSellerResult(
            sellerID: "acme", sellerName: seller, domain: domain, url: URL(string: url)!,
            price: price, currency: currency, productName: name, identifiers: identifiers,
            imageURL: nil, confidence: .gtin, source: .directory)
    }

    /// The payload must satisfy the SAME validator the page's own extraction
    /// goes through: a fan-out result and a visited page are one kind of thing,
    /// recorded through one `ProductSnapshotStore.makeSnapshot`.
    func testAFetchedResultBecomesAValidSnapshotRecord() {
        let snapshot = ProductSnapshotStore.makeSnapshot(
            fromPayload: result().snapshotPayload, now: now)
        XCTAssertEqual(snapshot?.name, "Widget 3000")
        XCTAssertEqual(snapshot?.price, "39.5")
        XCTAssertEqual(snapshot?.currency, "USD")
        XCTAssertEqual(snapshot?.url, "https://acme.example/p/1")
        XCTAssertEqual(snapshot?.host, "acme.example")
        XCTAssertEqual(snapshot?.day, UTCDay(now))
        XCTAssertEqual(snapshot?.gtin, "0012345678905")
        XCTAssertEqual(snapshot?.brand, "Widgets")
    }

    func testKeyedIdentifiersTheResultDidNotCarryAreOmittedRatherThanEmpty() {
        let payload = result(identifiers: ProductIdentifiers(mpn: "WX-1")).snapshotPayload
        XCTAssertEqual(payload["mpn"], "WX-1")
        XCTAssertNil(payload["gtin"])
        XCTAssertNil(payload["sku"])
        XCTAssertNil(payload["brand"])
    }

    func testAResultsPricePointIsStampedNowAndSoIsFresh() {
        let point = result().pricePoint(now: now)
        XCTAssertEqual(point.domain, "acme.example")
        XCTAssertEqual(point.urlString, "https://acme.example/p/1")
        XCTAssertTrue(FreshComparablePrices.isFresh(point.capturedAt, now: now))
    }
}
