//
//  SnapshotMatcherTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import LunaPriceCompare
import LunaPriceUI
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

    // MARK: - Tier 6: the fuzzy NAME tier, in scope only

    /// The reported bug, at matcher level: the Safari extension filed the
    /// observation under the page's CANONICAL url while the save is keyed by
    /// the url the user actually saved (`?variant=`), and the page declares no
    /// identifier at all. Every tier above has nothing to work with; the name
    /// on the same retailer is what is left.
    func testSameHostNameMatchRecoversAnObservationFiledUnderADifferentURL() {
        let canonical = snapshot(
            name: "Kestrel 6L Stainless Kettle", url: "https://shop.example/p/kettle",
            day: "2026-01-01", brand: "Kestrel")
        let result = SnapshotMatcher.matchingSnapshots(
            for: candidate(name: "Kestrel 6L Stainless Kettle", brand: "Kestrel"),
            candidateURL: URL(string: "https://shop.example/p/kettle?variant=blue")!,
            among: [canonical])
        XCTAssertEqual(result, [canonical])
    }

    func testNameMatchCrossesHostsOnlyWhenBothDeclareTheSameBrand() {
        let sameBrand = snapshot(
            name: "Acme Wireless Mechanical Keyboard", url: "https://a.example/p", brand: "Acme")
        let unbranded = snapshot(
            name: "Acme Wireless Mechanical Keyboard", url: "https://b.example/p")
        let result = SnapshotMatcher.matchingSnapshots(
            for: candidate(name: "Acme Wireless Mechanical Keyboard", brand: "Acme"),
            candidateURL: URL(string: "https://shop.example/p/9")!,
            among: [sameBrand, unbranded])
        XCTAssertEqual(
            result, [sameBrand],
            "an unbranded listing on an unrelated host is out of scope for a name match")
    }

    func testADifferentBrandBlocksANameMatchOnTheSameHost() {
        let otherBrand = snapshot(
            name: "Acme Wireless Mechanical Keyboard", url: "https://shop.example/p/1",
            brand: "Globex")
        let result = SnapshotMatcher.matchingSnapshots(
            for: candidate(name: "Acme Wireless Mechanical Keyboard", brand: "Acme"),
            candidateURL: URL(string: "https://shop.example/p/9")!,
            among: [otherBrand])
        XCTAssertTrue(result.isEmpty)
    }

    func testASharedWordIsNotANameMatch() {
        // One token in common out of six: far below the Jaccard threshold, so
        // the same shop's other keyboard is not this product.
        let neighbour = snapshot(
            name: "Globex Ultra Slim Bluetooth Travel Keyboard", url: "https://shop.example/p/1")
        let result = SnapshotMatcher.matchingSnapshots(
            for: candidate(name: "Acme Wireless Mechanical Keyboard Pro"),
            candidateURL: URL(string: "https://shop.example/p/9")!,
            among: [neighbour])
        XCTAssertTrue(result.isEmpty)
    }

    func testAnIdentifierMatchBeatsANameMatchOnAnotherPage() {
        let identified = snapshot(
            name: "Totally Different Title", url: "https://shop.example/p/1",
            day: "2026-01-01", gtin: "1234567890123", brand: "Acme")
        let nameTwin = snapshot(
            name: "Acme Wireless Mechanical Keyboard", url: "https://shop.example/p/2",
            day: "2026-01-02", brand: "Acme")
        let result = SnapshotMatcher.matchingSnapshots(
            for: candidate(name: "Acme Wireless Mechanical Keyboard", brand: "Acme",
                           productID: "1234567890123"),
            candidateURL: URL(string: "https://shop.example/p/9")!,
            among: [identified, nameTwin])
        XCTAssertEqual(
            result, [identified],
            "the name tier must never join an identifier tier's result")
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

    func testAGTINMatchWinsOverAWeakerURLTierCoincidence() {
        let gtinMatch = snapshot(name: "Totally Different Title", url: "https://a.example/p", gtin: "1234567890123")
        let urlOnly = snapshot(name: "Widget", url: "https://shop.example/p/9")
        let result = SnapshotMatcher.matchingSnapshots(
            for: candidate(name: "Widget", productID: "1234567890123"),
            candidateURL: URL(string: "https://shop.example/p/9")!,
            among: [gtinMatch, urlOnly])
        XCTAssertEqual(result, [gtinMatch], "GTIN precedence must exclude the weaker URL match")
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
