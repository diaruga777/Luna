//
//  SharedProductSnapshotsTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaPriceUI
import XCTest

/// `ProductSnapshotStore`'s validation/prune logic (round-trip, same-day
/// overwrite, age+count pruning, invalid-payload rejection) plus PARITY with
/// the Safari extension's own copy, `LunaSafari/SharedProductSnapshots.swift`
/// -- that target links no package, so it hand-rolls the identical path,
/// keys, and constants, checked here the same way `SafariSetupCelebrationTests`
/// pins `SharedSafariURL` against `LunaSetupStatusStore`: by reading the
/// extension's source text for the literals that must match.
final class SharedProductSnapshotsTests: XCTestCase {

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
        let snapshot = ProductSnapshotStore.makeSnapshot(
            fromPayload: payload(price: 49.99), now: Date())
        XCTAssertNotNil(snapshot)
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
        XCTAssertNil(ProductSnapshotStore.makeSnapshot(fromPayload: payload(price: "call for price"), now: Date()))
    }

    func testMalformedCurrencyIsRejected() {
        XCTAssertNil(ProductSnapshotStore.makeSnapshot(
            fromPayload: payload(currency: "US$"), now: Date()))
    }

    func testKeyedIdentifiersRoundTrip() {
        let snapshot = ProductSnapshotStore.makeSnapshot(
            fromPayload: payload(gtin: "0012345678905"), now: Date())
        XCTAssertEqual(snapshot?.gtin, "0012345678905")
    }

    // MARK: - Same-day overwrite / dedupe

    func testMergingOverwritesTheSameDaySameURLEntry() {
        let day1 = ProductSnapshotStore.makeSnapshot(fromPayload: payload(price: "10"), now: Date())!
        var list = [day1]
        let updated = ProductSnapshotStore.makeSnapshot(fromPayload: payload(price: "8"), now: Date())!
        list = ProductSnapshotStore.merging(updated, into: list)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].price, "8")
    }

    func testDifferentDayAppendsRatherThanOverwrites() {
        let today = ProductSnapshotStore.makeSnapshot(
            fromPayload: payload(), now: Date(timeIntervalSince1970: 1_800_000_000))!
        let tomorrow = ProductSnapshotStore.makeSnapshot(
            fromPayload: payload(), now: Date(timeIntervalSince1970: 1_800_086_400))!
        let merged = ProductSnapshotStore.merging(tomorrow, into: [today])
        XCTAssertEqual(merged.count, 2)
    }

    // MARK: - Pruning

    func testPruneDropsRecordsOlderThanMaxAge() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = ProductSnapshotStore.makeSnapshot(
            fromPayload: payload(url: "https://shop.example/old"),
            now: now.addingTimeInterval(-Double(ProductSnapshotStore.maxAgeDays + 5) * 86400))!
        let recent = ProductSnapshotStore.makeSnapshot(
            fromPayload: payload(url: "https://shop.example/recent"), now: now)!
        let pruned = ProductSnapshotStore.pruned([old, recent], now: now)
        XCTAssertEqual(pruned.map(\.url), ["https://shop.example/recent"])
    }

    func testPruneCapsTotalCountEvictingOldestFirst() {
        // Two days, both comfortably inside the age window, so this isolates
        // the COUNT cap from the age cutoff: 10 extra records on the older
        // day, exactly `maxCount` on the newer one.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let olderDay = now.addingTimeInterval(-2 * 86400)
        let newerDay = now.addingTimeInterval(-1 * 86400)
        var records: [ProductSnapshot] = []
        for i in 0..<10 {
            records.append(ProductSnapshotStore.makeSnapshot(
                fromPayload: payload(url: "https://shop.example/old\(i)"), now: olderDay)!)
        }
        for i in 0..<ProductSnapshotStore.maxCount {
            records.append(ProductSnapshotStore.makeSnapshot(
                fromPayload: payload(url: "https://shop.example/new\(i)"), now: newerDay)!)
        }
        let pruned = ProductSnapshotStore.pruned(records, now: now)
        XCTAssertEqual(pruned.count, ProductSnapshotStore.maxCount)
        XCTAssertFalse(pruned.contains { $0.url.hasPrefix("https://shop.example/old") },
                        "the older day's records must be evicted first")
    }

    // MARK: - Round trip through the actual file

    func testWriteThenLoadRoundTrips() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SharedProductSnapshotsTests-\(UUID().uuidString)")
        let fileURL = tempDir.appendingPathComponent("productSnapshots.json")
        let store = ProductSnapshotStore(fileURL: fileURL)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let snapshot = ProductSnapshotStore.makeSnapshot(fromPayload: payload(), now: Date())!
        store.write([snapshot])
        XCTAssertEqual(store.load(), [snapshot])
    }

    // MARK: - Parity with the extension's copy

    private static func extensionSource(_ relativePath: String) -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)) ?? ""
    }

    func testTheExtensionUsesTheSamePathAndFileName() {
        let source = Self.extensionSource("LunaSafari/SharedProductSnapshots.swift")
        XCTAssertFalse(source.isEmpty, "LunaSafari/SharedProductSnapshots.swift not found")
        XCTAssertTrue(source.contains("\"\(ProductSnapshotStore.relativeDirectory)\""))
        XCTAssertTrue(source.contains("\"\(ProductSnapshotStore.fileName)\""))
    }

    func testTheExtensionUsesTheSamePruneConstants() {
        let source = Self.extensionSource("LunaSafari/SharedProductSnapshots.swift")
        XCTAssertTrue(source.contains("= \(ProductSnapshotStore.maxAgeDays)"))
        XCTAssertTrue(source.contains("= \(ProductSnapshotStore.maxCount)"))
    }

    func testTheExtensionRecordHasTheSameFields() {
        let source = Self.extensionSource("LunaSafari/SharedProductSnapshots.swift")
        for field in ["name", "price", "currency", "url", "host", "day", "capturedAt",
                      "gtin", "mpn", "sku", "productID", "retailerItemID", "brand"] {
            XCTAssertTrue(
                source.contains("var \(field):"),
                "SharedProductSnapshots.Record has no \"\(field)\" field")
        }
    }

    func testTheHandlerGatesOnProductSupportAndRecordsTheMessage() {
        let handler = Self.extensionSource("LunaSafari/SafariWebExtensionHandler.swift")
        XCTAssertTrue(handler.contains("\"productSnapshot\""))
        XCTAssertTrue(handler.contains("hostHandlesProducts"))
        let background = Self.extensionSource("LunaSafari/Resources/background.js")
        XCTAssertTrue(background.contains("productSnapshot"))
    }

    // MARK: - The alternative-seller lookup writes through the same store

    /// A price the constrained fan-out fetched is not a second kind of thing:
    /// it goes in through `SharedProductSnapshots.record`, the ONE write path,
    /// so it prunes with everything else and feeds the "Was $X" pill and a
    /// later save's seeded history without a second file.
    func testTheSellerLookupWritesItsResultsThroughTheSnapshotStore() {
        let finder = Self.extensionSource("LunaSafari/ComparableSellerFinder.swift")
        XCTAssertFalse(finder.isEmpty, "LunaSafari/ComparableSellerFinder.swift not found")
        XCTAssertTrue(
            finder.contains("SharedProductSnapshots.record("),
            "fetched comparison results must be recorded through the shared store")
        XCTAssertTrue(
            finder.contains("snapshotPayload"),
            "the record payload should be LunaPriceCompare's, not a Safari-local shape")
        XCTAssertTrue(
            finder.contains("SellerFanOutProfile.constrained"),
            "the appex must run the constrained profile, never the full one")
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
