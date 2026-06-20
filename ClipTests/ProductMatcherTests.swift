//
//  ProductMatcherTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Coverage for `ProductMatcher`: product-id equality, fuzzy name+brand matching,
/// brand compatibility, and the no-match case.
final class ProductMatcherTests: XCTestCase {

    private func tracker(name: String, brand: String? = nil, id: String? = nil) -> PriceTracker {
        var tracker = PriceTracker(
            productName: name, firstStoreURL: "https://x.example/p",
            price: Decimal(10), currency: "USD")
        tracker.brand = brand
        tracker.productID = id
        return tracker
    }

    private func candidate(name: String, brand: String? = nil, id: String? = nil) -> ProductInfo {
        ProductInfo(name: name, priceAmount: Decimal(10), priceCurrency: "USD",
                    imageURL: nil, brand: brand, productID: id)
    }

    func testProductIDExactMatchWins() {
        let a = UUID(); let b = UUID()
        let existing = [
            (id: a, tracker: tracker(name: "Totally Different", id: "sku-1")),
            (id: b, tracker: tracker(name: "Sony Headphones", id: "gtin-99")),
        ]
        let match = ProductMatcher.bestMatch(
            for: candidate(name: "Anything", id: "SKU1"), among: existing)
        XCTAssertEqual(match, a, "normalized product id match beats name")
    }

    func testFuzzyNameMatchWithCompatibleBrand() {
        let a = UUID()
        let existing = [(id: a, tracker: tracker(
            name: "Sony WH-1000XM5 Wireless Headphones", brand: "Sony"))]
        let match = ProductMatcher.bestMatch(
            for: candidate(name: "Sony WH-1000XM5 Wireless Noise Canceling Headphones", brand: "Sony"),
            among: existing)
        XCTAssertEqual(match, a)
    }

    func testDifferentBrandBlocksNameMatch() {
        let a = UUID()
        let existing = [(id: a, tracker: tracker(name: "Wireless Headphones", brand: "Sony"))]
        let match = ProductMatcher.bestMatch(
            for: candidate(name: "Wireless Headphones", brand: "Bose"), among: existing)
        XCTAssertNil(match)
    }

    func testUnbrandedSideStillMatchesOnName() {
        let a = UUID()
        let existing = [(id: a, tracker: tracker(
            name: "Hario V60 Ceramic Coffee Dripper White", brand: "Hario"))]
        let match = ProductMatcher.bestMatch(
            for: candidate(name: "Hario V60 Ceramic Coffee Dripper White", brand: nil),
            among: existing)
        XCTAssertEqual(a, match)
    }

    func testNoMatchBelowThreshold() {
        let existing = [(id: UUID(), tracker: tracker(name: "Apple iPhone 15 Pro Max"))]
        let match = ProductMatcher.bestMatch(
            for: candidate(name: "Samsung Galaxy Watch Ultra"), among: existing)
        XCTAssertNil(match)
    }

    func testPicksHighestScoringCandidate() {
        let near = UUID(); let far = UUID()
        let existing = [
            (id: far, tracker: tracker(name: "Anker USB Charger")),
            (id: near, tracker: tracker(name: "Anker 715 USB-C Charger Nano II 65W")),
        ]
        let match = ProductMatcher.bestMatch(
            for: candidate(name: "Anker 715 USB-C Charger Nano II 65W"), among: existing)
        XCTAssertEqual(match, near)
    }
}
