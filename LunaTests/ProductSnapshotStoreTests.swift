//
//  ProductSnapshotStoreTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import LunaPriceCompare
import LunaPriceUI
import XCTest

/// The shared product-snapshot store: what it accepts, what the index retrieves,
/// and what pruning evicts.
///
/// One implementation now serves the app, the share/action extensions AND the
/// Safari appexes (`LunaPriceCompare` is the one kind module an appex links), so
/// the hand-copied `LunaSafari/SharedProductSnapshots.swift` — and the source-text
/// parity suite that pinned it — are gone. What remains of the Safari pins here
/// is only what still IS a second artifact: the JS/handler message plumbing.
final class ProductSnapshotStoreTests: XCTestCase {

    private var directory: URL!
    private var store: ProductSnapshotStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProductSnapshotStoreTests-\(UUID().uuidString)")
        store = ProductSnapshotStore(directoryURL: directory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func payload(
        name: String = "Widget", price: Any = "49.99", currency: String = "USD",
        url: String = "https://shop.example/p/1", gtin: String? = nil
    ) -> [String: Any] {
        var dict: [String: Any] = ["name": name, "price": price, "currency": currency, "url": url]
        if let gtin { dict["gtin"] = gtin }
        return dict
    }

    // MARK: - Validation

    func testValidPayloadProducesASnapshot() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = ProductSnapshotStore.makeSnapshot(fromPayload: payload(), now: now)
        XCTAssertEqual(snapshot?.name, "Widget")
        XCTAssertEqual(snapshot?.price, "49.99")
        XCTAssertEqual(snapshot?.currency, "USD")
        XCTAssertEqual(snapshot?.host, "shop.example")
        XCTAssertEqual(snapshot?.day, ProductSnapshotStore.dayString(for: now))
    }

    func testNumericPriceIsAccepted() {
        XCTAssertNotNil(ProductSnapshotStore.makeSnapshot(
            fromPayload: payload(price: 49.99), now: Date()))
    }

    func testNonHTTPURLIsRejected() {
        XCTAssertNil(ProductSnapshotStore.makeSnapshot(
            fromPayload: payload(url: "ftp://shop.example/p/1"), now: Date()))
    }

    func testEmptyNameIsRejected() {
        XCTAssertNil(ProductSnapshotStore.makeSnapshot(fromPayload: payload(name: "  "), now: Date()))
    }

    func testZeroOrNegativePriceIsRejected() {
        XCTAssertNil(ProductSnapshotStore.makeSnapshot(fromPayload: payload(price: "0"), now: Date()))
        XCTAssertNil(ProductSnapshotStore.makeSnapshot(fromPayload: payload(price: "-5"), now: Date()))
    }

    func testNonNumericPriceIsRejected() {
        XCTAssertNil(ProductSnapshotStore.makeSnapshot(
            fromPayload: payload(price: "call for price"), now: Date()))
    }

    /// The meta/microdata capture tiers hand over the page's RAW price text —
    /// "$1,299.00", not "1299.00" — and `Decimal(string:)` refuses it outright.
    /// The SANITIZED string is what persists, so `priceAmount` parses back
    /// instead of silently dropping every such visit.
    func testASymbolAndCommaDecoratedPriceIsSanitizedAndKept() throws {
        let snapshot = try XCTUnwrap(ProductSnapshotStore.makeSnapshot(
            fromPayload: payload(price: "$1,299.00"), now: Date()))
        XCTAssertEqual(snapshot.price, "1299.00")
        XCTAssertEqual(snapshot.priceAmount, Decimal(string: "1299.00"))
    }

    func testACurrencyPrefixedPriceIsSanitizedAndKept() throws {
        let snapshot = try XCTUnwrap(ProductSnapshotStore.makeSnapshot(
            fromPayload: payload(price: "AU$59.95"), now: Date()))
        XCTAssertEqual(snapshot.price, "59.95")
    }

    func testMalformedCurrencyIsRejected() {
        XCTAssertNil(ProductSnapshotStore.makeSnapshot(
            fromPayload: payload(currency: "US$"), now: Date()))
    }

    // MARK: - Indexed retrieval

    /// The point of the index: a lookup by ONE identifier finds the observation
    /// without the caller ever naming the URL it was taken on, and does not drag
    /// in the unrelated observations sitting beside it.
    func testAnObservationIsFoundByEachIdentifierItDeclared() throws {
        var value = payload(url: "https://shop.example/p/xm5")
        value["gtin"] = "0012345678905"
        value["mpn"] = "WH1000XM5"
        value["sku"] = "SKU-42"
        XCTAssertTrue(store.record(payload: value))
        store.record(payload: payload(url: "https://other.example/p/unrelated"))

        XCTAssertEqual(
            store.snapshots(forKeys: ProductSnapshotKeys.gtinKeys("00012345678905")).map(\.url),
            ["https://shop.example/p/xm5"])
        XCTAssertEqual(
            store.snapshots(forKeys: ProductSnapshotKeys.mpnKeys("wh1000xm5")).map(\.url),
            ["https://shop.example/p/xm5"])
        XCTAssertEqual(
            store.snapshots(forKeys: ProductSnapshotKeys.skuKeys("sku42", host: "shop.example"))
                .map(\.url),
            ["https://shop.example/p/xm5"])
    }

    /// A retailer SKU means nothing on another host, so the key carries the host
    /// and a lookup from elsewhere misses.
    func testARetailerScopedKeyDoesNotMatchAnotherHost() {
        var value = payload(url: "https://shop.example/p/1")
        value["sku"] = "SKU-42"
        store.record(payload: value)
        XCTAssertTrue(
            store.snapshots(forKeys: ProductSnapshotKeys.skuKeys("SKU-42", host: "rival.example"))
                .isEmpty)
    }

    /// The name buckets: a page that declared no identifier at all is still
    /// retrievable — by a word of its name, within its own retailer family or
    /// its own brand — which is what keeps the fuzzy tier a LOOKUP.
    func testAnIdentifierLessObservationIsFoundByANameTokenInScope() {
        var value = payload(name: "Kestrel 6L Stainless Kettle", url: "https://shop.example/p/kettle")
        value["brand"] = "Kestrel"
        XCTAssertTrue(store.record(payload: value))
        store.record(payload: payload(name: "Unrelated Thing", url: "https://shop.example/p/other"))

        let inScope = ProductSnapshotKeys.nameKeys(
            "Kestrel 6L Stainless Kettle Blue", brand: "Kestrel", host: "shop.example")
        XCTAssertEqual(
            store.snapshots(forKeys: inScope).map(\.url), ["https://shop.example/p/kettle"])

        let otherBrandElsewhere = ProductSnapshotKeys.nameKeys(
            "Kestrel 6L Stainless Kettle", brand: "Globex", host: "rival.example")
        XCTAssertTrue(
            store.snapshots(forKeys: otherBrandElsewhere).isEmpty,
            "a name bucket is scoped to a brand or a retailer family, never global")
    }

    /// The name pool is a guess, so it is capped — and the cap keeps the NEWEST
    /// days, decided from the index alone.
    func testALimitedLookupKeepsTheNewestObservations() {
        for day in 1...5 {
            let now = ProductSnapshotStore.date(forDay: "2026-01-0\(day)")!
            store.record(
                payload: payload(name: "Kestrel Kettle", url: "https://shop.example/p/\(day)"),
                now: now)
        }
        let keys = ProductSnapshotKeys.nameKeys("Kestrel Kettle", brand: nil, host: "shop.example")
        let limited = store.snapshots(forKeys: keys, limit: 2)
        XCTAssertEqual(limited.map(\.day), ["2026-01-04", "2026-01-05"])
        XCTAssertEqual(store.snapshots(forKeys: keys).count, 5)
    }

    func testAKeyNothingWasFiledUnderReturnsNothing() {
        store.record(payload: payload(gtin: "0012345678905"))
        XCTAssertTrue(store.snapshots(forKeys: ProductSnapshotKeys.gtinKeys("9999999999999")).isEmpty)
    }

    // MARK: - Same-day overwrite / dedupe

    func testRevisitingAPageTheSameDayUpdatesRatherThanAccumulates() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.record(payload: payload(price: "10"), now: now)
        store.record(payload: payload(price: "8"), now: now)
        let stored = store.allSnapshots()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.price, "8")
    }

    func testTheNextDayIsASecondObservationOfTheSamePage() {
        store.record(payload: payload(), now: Date(timeIntervalSince1970: 1_800_000_000))
        store.record(payload: payload(), now: Date(timeIntervalSince1970: 1_800_086_400))
        XCTAssertEqual(store.count(), 2)
    }

    // MARK: - Pruning

    func testAnObservationPastTheAgeLimitIsEvictedAndItsRecordDeleted() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.record(
            payload: payload(url: "https://shop.example/old"),
            now: now.addingTimeInterval(-Double(ProductSnapshotStore.maxAgeDays + 5) * 86400))
        store.record(payload: payload(url: "https://shop.example/recent"), now: now)

        XCTAssertEqual(store.allSnapshots().map(\.url), ["https://shop.example/recent"])
        let records = (try? FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("records"), includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(records.count, 1, "the evicted record's file must be deleted, not orphaned")
    }

    /// The count cap evicts the OLDEST day first, and the key index must lose
    /// the evicted ids with it — a key still pointing at a deleted record is a
    /// lookup that silently returns fewer results than it claims.
    func testTheCountCapEvictsTheOldestDayAndForgetsItsKeys() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let small = ProductSnapshotStore(directoryURL: directory, maxCount: 3)
        var oldest = payload(url: "https://shop.example/oldest")
        oldest["gtin"] = "0000000000017"
        small.record(payload: oldest, now: now.addingTimeInterval(-3 * 86400))
        for index in 0..<3 {
            small.record(
                payload: payload(url: "https://shop.example/new\(index)"),
                now: now.addingTimeInterval(-1 * 86400))
        }
        XCTAssertEqual(small.count(), 3)
        XCTAssertFalse(small.allSnapshots().contains { $0.url.hasSuffix("/oldest") })
        XCTAssertTrue(
            small.snapshots(forKeys: ProductSnapshotKeys.gtinKeys("0000000000017")).isEmpty,
            "an evicted record must not still be reachable through the index")
    }

    // MARK: - The Amazon bot-wall fallback

    /// Amazon changes slugs and appends `/ref=…` freely, so the URL key alone
    /// would miss. The ASIN is the page identity, and the fallback has to find
    /// the observation Safari took of the RENDERED page.
    func testTheFallbackFindsAnAmazonObservationUnderADifferentSlug() throws {
        var value = payload(
            name: "Sony WH-1000XM5", price: "350.97", currency: "AUD",
            url: "https://www.amazon.com.au/Sony/dp/B09XS7JWHH")
        value["sku"] = "B09XS7JWHH"
        value["retailerItemID"] = "B09XS7JWHH"
        value["brand"] = "Sony"
        value["imageURL"] = "https://m.media-amazon.com/images/I/xm5.jpg"
        XCTAssertTrue(store.record(payload: value))

        let info = try XCTUnwrap(store.productInfo(forPageURL: URL(string:
            "https://www.amazon.com.au/Different-Slug/dp/B09XS7JWHH/ref=abc?th=1")!))
        XCTAssertEqual(info.identifiers.sku, "B09XS7JWHH")
        XCTAssertEqual(info.productID, "B09XS7JWHH")
        XCTAssertEqual(info.imageURL?.absoluteString, value["imageURL"] as? String)
        XCTAssertEqual(info.priceAmount, Decimal(string: "350.97"))
    }

    // MARK: - The Safari message plumbing (still a second artifact)

    private static func extensionSource(_ relativePath: String) -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)) ?? ""
    }

    func testTheHandlerGatesOnProductSupportAndRecordsTheMessage() {
        let handler = Self.extensionSource("LunaSafari/SafariWebExtensionHandler.swift")
        XCTAssertTrue(handler.contains("\"productSnapshot\""))
        XCTAssertTrue(handler.contains("hostHandlesProducts"))
        let background = Self.extensionSource("LunaSafari/Resources/background.js")
        XCTAssertTrue(background.contains("productSnapshot"))
    }

    func testTheHandlerRelaysTheSellerLookupAndGatesItOnProductSupport() {
        let handler = Self.extensionSource("LunaSafari/SafariWebExtensionHandler.swift")
        XCTAssertTrue(handler.contains("\"comparableSellers\""))
        XCTAssertTrue(handler.contains("ComparableSellerFinder.answer("))
        let background = Self.extensionSource("LunaSafari/Resources/background.js")
        XCTAssertTrue(background.contains("comparableSellers"))
        let content = Self.extensionSource("LunaSafari/Resources/content.js")
        XCTAssertTrue(content.contains("type: \"comparableSellers\""))
    }

    /// The finder must give up BEFORE the handler's own notion of too-long, so
    /// the page's promise settles with a real answer rather than a timeout.
    func testTheFindersBudgetSitsInsideTheHandlersNativeBudget() throws {
        let finder = Self.extensionSource("LunaSafari/ComparableSellerFinder.swift")
        let handler = Self.extensionSource("LunaSafari/SafariWebExtensionHandler.swift")
        let finderBudget = try XCTUnwrap(
            Self.firstDouble(after: "static let budget: TimeInterval = ", in: finder))
        let handlerBudget = try XCTUnwrap(
            Self.firstDouble(after: "resolveTimeout: TimeInterval = ", in: handler))
        XCTAssertLessThan(finderBudget, handlerBudget)
    }

    private static func firstDouble(after marker: String, in source: String) -> Double? {
        guard let range = source.range(of: marker) else { return nil }
        let digits = source[range.upperBound...].prefix { $0.isNumber || $0 == "." }
        return Double(digits)
    }
}
