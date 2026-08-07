//
//  SnapshotMatcherTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import XCTest

/// `SnapshotMatcher`: each precedence tier, host-family scoping, sku-same-host,
/// brand-blocked fuzzy matching, and determinism under input reordering.
final class SnapshotMatcherTests: XCTestCase {

    private func snapshot(
        name: String = "Widget", price: String = "50.00", currency: String = "USD",
        url: String, day: String = "2026-01-01",
        gtin: String? = nil, mpn: String? = nil, sku: String? = nil,
        productID: String? = nil, retailerItemID: String? = nil, brand: String? = nil
    ) -> ProductSnapshot {
        ProductSnapshot(
            name: name, price: price, currency: currency, url: url,
            host: URL(string: url)!.host!, day: day, capturedAt: "\(day)T00:00:00Z",
            gtin: gtin, mpn: mpn, sku: sku, productID: productID,
            retailerItemID: retailerItemID, brand: brand)
    }

    private func candidate(
        name: String = "Widget", brand: String? = nil, productID: String? = nil
    ) -> ProductInfo {
        ProductInfo(
            name: name, priceAmount: Decimal(string: "60")!, priceCurrency: "USD",
            imageURL: nil, brand: brand, productID: productID)
    }

    // MARK: - Tier 1: GTIN/ISBN, cross-host

    func testGTINMatchesAcrossHosts() {
        let match = snapshot(url: "https://retailer-a.example/p/1", gtin: "0012345678905")
        let unrelated = snapshot(url: "https://retailer-b.example/p/2", gtin: "9999999999999")
        let result = SnapshotMatcher.matchingSnapshots(
            for: candidate(productID: "0012345678905"),
            candidateURL: URL(string: "https://shop.example/p/9")!,
            among: [match, unrelated])
        XCTAssertEqual(result, [match])
    }

    func testGTINZeroPadWidthDifferenceStillMatches() {
        // Candidate carries a 12-digit UPC; the snapshot recorded the 13-digit
        // GTIN form of the SAME number -- both zero-pad to the same 14 digits.
        let match = snapshot(url: "https://retailer-a.example/p/1", gtin: "012345678905")
        let result = SnapshotMatcher.matchingSnapshots(
            for: candidate(productID: "12345678905"),
            candidateURL: URL(string: "https://shop.example/p/9")!,
            among: [match])
        XCTAssertEqual(result, [match])
    }

    // MARK: - Tier 2: retailerItemID, same retailer family only

    func testRetailerItemIDMatchesOnlyWithinHostFamily() {
        let sameFamily = snapshot(url: "https://smile.amazon.com/dp/B000TEST1", retailerItemID: "B000TEST1")
        let otherFamily = snapshot(url: "https://amazon.co.jp/dp/B000TEST1", retailerItemID: "B000TEST1")
        let result = SnapshotMatcher.matchingSnapshots(
            for: candidate(productID: "B000TEST1"),
            candidateURL: URL(string: "https://www.amazon.com/dp/B000TEST1")!,
            among: [sameFamily, otherFamily])
        XCTAssertEqual(result, [sameFamily], "an ASIN must not match across amazon national storefronts")
    }

    // MARK: - Tier 3: mpn, brand-gated

    func testMPNRequiresCompatibleBrand() {
        let compatible = snapshot(url: "https://retailer-a.example/p/1", mpn: "MPN-1", brand: "Acme")
        let incompatible = snapshot(url: "https://retailer-b.example/p/2", mpn: "MPN-1", brand: "Globex")
        let result = SnapshotMatcher.matchingSnapshots(
            for: candidate(brand: "Acme", productID: "MPN-1"),
            candidateURL: URL(string: "https://shop.example/p/9")!,
            among: [compatible, incompatible])
        XCTAssertEqual(result, [compatible], "a conflicting brand must block an MPN match")
    }

    // MARK: - Tier 4: sku, same host only

    func testSKUMatchesOnlyOnTheSameHost() {
        let sameHost = snapshot(url: "https://shop.example/p/1", sku: "SKU-1")
        let otherHost = snapshot(url: "https://other.example/p/1", sku: "SKU-1")
        let result = SnapshotMatcher.matchingSnapshots(
            for: candidate(productID: "SKU-1"),
            candidateURL: URL(string: "https://shop.example/p/9")!,
            among: [sameHost, otherHost])
        XCTAssertEqual(result, [sameHost])
    }

    // MARK: - Tier 5: canonical URL

    func testCanonicalURLMatchIgnoresTrackingParams() {
        let match = snapshot(url: "https://shop.example/p/1?utm_source=newsletter&gclid=abc")
        let result = SnapshotMatcher.matchingSnapshots(
            for: candidate(),
            candidateURL: URL(string: "https://shop.example/p/1?srsltid=xyz")!,
            among: [match])
        XCTAssertEqual(result, [match])
    }

    func testCanonicalURLMatchesAnExistingTrackerStoreURLToo() {
        let match = snapshot(url: "https://shop.example/p/1")
        let result = SnapshotMatcher.matchingSnapshots(
            for: candidate(name: "Completely Different Name"),
            candidateURL: URL(string: "https://shop.example/p/OTHER")!,
            existingStoreURLStrings: ["https://shop.example/p/1"],
            among: [match])
        XCTAssertEqual(result, [match])
    }

    // MARK: - Tier 6: fuzzy name, brand-gated

    func testFuzzyNameRequiresCompatibleBrandAndThreshold() {
        let closeEnough = snapshot(
            name: "Acme Wireless Mechanical Keyboard", url: "https://a.example/p", brand: "Acme")
        let tooDifferent = snapshot(name: "Totally Unrelated Item", url: "https://b.example/p", brand: "Acme")
        let wrongBrand = snapshot(
            name: "Acme Wireless Mechanical Keyboard", url: "https://c.example/p", brand: "Globex")
        let result = SnapshotMatcher.matchingSnapshots(
            for: candidate(name: "Acme Wireless Mechanical Keyboard Pro", brand: "Acme"),
            candidateURL: URL(string: "https://shop.example/p/9")!,
            among: [closeEnough, tooDifferent, wrongBrand])
        XCTAssertEqual(result, [closeEnough])
    }

    func testNoTierMatchesReturnsEmpty() {
        let unrelated = snapshot(name: "Something Else Entirely", url: "https://a.example/p")
        let result = SnapshotMatcher.matchingSnapshots(
            for: candidate(name: "Widget"),
            candidateURL: URL(string: "https://shop.example/p/9")!,
            among: [unrelated])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Precedence: a higher tier wins outright

    func testAGTINMatchWinsOverAWeakerFuzzyNameCoincidence() {
        let gtinMatch = snapshot(name: "Totally Different Title", url: "https://a.example/p", gtin: "1234567890123")
        let fuzzyOnly = snapshot(name: "Widget", url: "https://b.example/p")
        let result = SnapshotMatcher.matchingSnapshots(
            for: candidate(name: "Widget", productID: "1234567890123"),
            candidateURL: URL(string: "https://shop.example/p/9")!,
            among: [gtinMatch, fuzzyOnly])
        XCTAssertEqual(result, [gtinMatch], "GTIN precedence must exclude the weaker fuzzy-name match")
    }

    // MARK: - Determinism

    func testResultIsOrderStableRegardlessOfInputOrder() {
        let a = snapshot(url: "https://a.example/p", day: "2026-01-03", gtin: "1234567890123")
        let b = snapshot(url: "https://b.example/p", day: "2026-01-01", gtin: "1234567890123")
        let c = snapshot(url: "https://c.example/p", day: "2026-01-02", gtin: "1234567890123")
        let cand = candidate(productID: "1234567890123")
        let url = URL(string: "https://shop.example/p/9")!

        let forward = SnapshotMatcher.matchingSnapshots(for: cand, candidateURL: url, among: [a, b, c])
        let shuffled = SnapshotMatcher.matchingSnapshots(for: cand, candidateURL: url, among: [c, a, b])
        XCTAssertEqual(forward, shuffled)
        XCTAssertEqual(forward.map(\.url), ["https://b.example/p", "https://c.example/p", "https://a.example/p"])
    }
}
