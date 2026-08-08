//
//  ProductMatcherTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import XCTest
@testable import Luna

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

    private func trackerWithGTIN(_ gtin: String, name: String = "Tracked", id: String? = nil)
        -> PriceTracker {
        var subject = tracker(name: name, id: id)
        subject.identifiers = ProductIdentifiers(gtin: gtin)
        return subject
    }

    private func candidateWithGTIN(_ gtin: String, name: String = "Candidate", id: String? = nil)
        -> ProductInfo {
        ProductInfo(name: name, priceAmount: Decimal(10), priceCurrency: "USD",
                    imageURL: nil, brand: nil, productID: id,
                    identifiers: ProductIdentifiers(gtin: gtin))
    }

    /// A keyed GTIN outranks a flattened `productID` collision: two equal GTINs
    /// are the same physical product by definition, while two equal flattened ids
    /// can be unrelated retailer SKUs that happen to read alike.
    func testKeyedGTINBeatsFlattenedProductIDMatch() {
        let gtinTracker = UUID(), flatTracker = UUID()
        let existing = [
            (id: gtinTracker, tracker: trackerWithGTIN("0194644090876")),
            (id: flatTracker, tracker: tracker(name: "Other", id: "SKU-1")),
        ]
        let candidate = candidateWithGTIN("0194644090876", id: "SKU1")
        XCTAssertEqual(ProductMatcher.bestMatch(for: candidate, among: existing), gtinTracker)
    }

    /// GTIN-8/12/13/14 are the same numberspace at different widths.
    func testKeyedGTINMatchesAcrossDeclaredWidths() {
        let a = UUID()
        let existing = [(id: a, tracker: trackerWithGTIN("0194644090876"))]
        XCTAssertEqual(
            ProductMatcher.bestMatch(for: candidateWithGTIN("194644090876"), among: existing), a)
    }

    func testDifferentKeyedGTINsDoNotMatch() {
        let a = UUID()
        let existing = [(id: a, tracker: trackerWithGTIN("0194644090876", name: "Sony Headphones"))]
        XCTAssertNil(
            ProductMatcher.bestMatch(
                for: candidateWithGTIN("9999999999999", name: "Bose Speaker"), among: existing))
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

    /// Two equally-scoring trackers (identical names) must resolve to the SAME tracker
    /// regardless of the order `existing` is presented in — the lowest id. A re-save
    /// must never pick a different match run to run.
    func testEqualScoreTieBreaksDeterministicallyByLowestID() {
        let lower = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higher = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let name = "Ryobi 18V ONE+ Cordless Line Trimmer"
        let forward = [
            (id: higher, tracker: tracker(name: name)),
            (id: lower, tracker: tracker(name: name)),
        ]
        XCTAssertEqual(ProductMatcher.bestMatch(for: candidate(name: name), among: forward), lower)
        XCTAssertEqual(ProductMatcher.bestMatch(for: candidate(name: name), among: forward.reversed()), lower,
                       "Tie-break must not depend on input order.")
    }

    /// Several trackers sharing the candidate's product id resolve to the lowest id,
    /// independent of input order.
    func testProductIDTieBreaksDeterministicallyByLowestID() {
        let lower = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let higher = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFE")!
        let existing = [
            (id: higher, tracker: tracker(name: "A", id: "GTIN-5")),
            (id: lower, tracker: tracker(name: "B", id: "gtin5")),
        ]
        XCTAssertEqual(ProductMatcher.bestMatch(for: candidate(name: "X", id: "GTIN5"), among: existing), lower)
        XCTAssertEqual(
            ProductMatcher.bestMatch(for: candidate(name: "X", id: "GTIN5"), among: existing.reversed()), lower)
    }
}
