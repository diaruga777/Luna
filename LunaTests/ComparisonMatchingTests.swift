//
//  ComparisonMatchingTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import LunaPriceCompare
import LunaPriceUI
import XCTest

/// The one decision the feature's credibility rests on: is the page we landed
/// on at another retailer THE SAME PRODUCT? A wrong "$9.50 at Amazon" is worse
/// than no answer at all, so the tiers are strict and the weakest one is
/// deliberately narrow.
final class ComparisonMatchingTests: XCTestCase {

    private func verify(
        source: ProductIdentifiers, sourceName: String = "Sony WH-1000XM5 Headphones",
        candidate: ProductIdentifiers, candidateName: String = "Sony WH-1000XM5 Headphones",
        allowsNameOnlyMatch: Bool = true
    ) -> SellerMatchConfidence? {
        ComparisonMatching.verify(
            source: source, sourceName: sourceName,
            candidate: candidate, candidateName: candidateName,
            allowsNameOnlyMatch: allowsNameOnlyMatch)
    }

    // MARK: - Tiers

    func testEqualGTINsMatchAcrossDeclaredWidths() {
        XCTAssertEqual(
            verify(source: ProductIdentifiers(gtin: "0194644090876"),
                   candidate: ProductIdentifiers(gtin: "194644090876")),
            .gtin)
    }

    /// Two GTINs that differ are a REFUSAL, not a fall-through to a weaker tier:
    /// both sides named the product globally and they named different products.
    func testDifferentGTINsRefuseEvenWithIdenticalNames() {
        XCTAssertNil(
            verify(source: ProductIdentifiers(gtin: "0194644090876", brand: "Sony"),
                   candidate: ProductIdentifiers(gtin: "9999999999999", brand: "Sony")))
    }

    func testMPNMatchesOnlyWithACompatibleBrand() {
        XCTAssertEqual(
            verify(source: ProductIdentifiers(mpn: "WH-1000XM5", brand: "Sony"),
                   candidate: ProductIdentifiers(mpn: "wh1000xm5", brand: "SONY")),
            .mpn)
        XCTAssertNil(
            verify(source: ProductIdentifiers(mpn: "WH-1000XM5", brand: "Sony"),
                   candidate: ProductIdentifiers(mpn: "WH-1000XM5", brand: "Bose"),
                   candidateName: "Bose Something Else"))
        // An unbranded listing does not block an MPN match.
        XCTAssertEqual(
            verify(source: ProductIdentifiers(mpn: "WH-1000XM5", brand: "Sony"),
                   candidate: ProductIdentifiers(mpn: "WH-1000XM5")),
            .mpn)
    }

    func testNameMatchNeedsBrandCompatibilityAndTheThreshold() {
        XCTAssertEqual(
            verify(source: ProductIdentifiers(brand: "Sony"),
                   candidate: ProductIdentifiers(brand: "Sony")),
            .name)
        XCTAssertNil(
            verify(source: ProductIdentifiers(brand: "Sony"),
                   candidate: ProductIdentifiers(brand: "Sony"),
                   candidateName: "Bose QuietComfort Ultra Earbuds"))
    }

    /// The narrow part: when the source HAS a strong id and the candidate does
    /// not present the same one, a name coincidence is not evidence — it is the
    /// case, the older model, or the two-pack.
    func testNameMatchIsRefusedWhenTheSourceHasACrossHostIdentifier() {
        XCTAssertNil(
            verify(source: ProductIdentifiers(gtin: "0194644090876", brand: "Sony"),
                   candidate: ProductIdentifiers(brand: "Sony")))
        XCTAssertNil(
            verify(source: ProductIdentifiers(mpn: "WH-1000XM5", brand: "Sony"),
                   candidate: ProductIdentifiers(brand: "Sony")))
        // A retailer SKU is not a cross-host identifier, so it does not block it.
        XCTAssertEqual(
            verify(source: ProductIdentifiers(sku: "A-42", brand: "Sony"),
                   candidate: ProductIdentifiers(brand: "Sony")),
            .name)
    }

    /// The Safari profile turns the name tier off entirely — a wrong pill on
    /// someone's shopping page costs more than a missing one.
    func testConstrainedProfileRefusesNameOnlyMatches() {
        XCTAssertNil(
            verify(source: ProductIdentifiers(brand: "Sony"),
                   candidate: ProductIdentifiers(brand: "Sony"),
                   allowsNameOnlyMatch: false))
    }

    func testConfidenceIsOrdered() {
        XCTAssertTrue(SellerMatchConfidence.gtin > SellerMatchConfidence.mpn)
        XCTAssertTrue(SellerMatchConfidence.mpn > SellerMatchConfidence.name)
    }
}

/// `LunaPriceCompare` must not link LunaHTMLClassification (SwiftSoup would not
/// fit in the Safari appex), so the normalization primitives it matches on live
/// in LunaModels. This pins them to `ProductMatcher`/`SnapshotMatcher`'s
/// long-standing copies, which the save/merge and snapshot-seeding paths still
/// use — one silent divergence and the same product would match in the app and
/// not in the extension.
final class ComparisonMatchingParityTests: XCTestCase {

    private func snapshot(name: String, gtin: String? = nil, brand: String? = nil)
        -> ProductSnapshot {
        ProductSnapshot(
            name: name, price: "10", currency: "USD", url: "https://a.example/p",
            host: "a.example", day: UTCDay(parsing: "2026-01-01")!,
            capturedAt: "2026-01-01T00:00:00Z",
            gtin: gtin, mpn: nil, sku: nil, retailerItemID: nil, brand: brand)
    }

    private func candidate(name: String, brand: String? = nil, productID: String? = nil)
        -> ProductInfo {
        ProductInfo(name: name, priceAmount: 10, priceCurrency: "USD",
                    imageURL: nil, brand: brand, productID: productID)
    }

    /// GTIN normalization has to agree with `SnapshotMatcher`'s tier 1, which is
    /// only reachable behaviourally.
    func testGTINNormalizationAgreesWithSnapshotMatcherTierOne() {
        let pairs: [(String, String)] = [
            ("0194644090876", "194644090876"),
            ("12345670", "0000012345670"),
            ("0194644090876", "0194644090876"),
            ("0194644090876", "9999999999999"),
            ("080442957X", "080442957X"),
            ("080442957X", "0080442957X"),
        ]
        let url = URL(string: "https://b.example/p")!
        for (left, right) in pairs {
            let ours = ProductIdentityMatching.normalizedGTIN(
                ProductIdentityMatching.normalizedID(left))
                == ProductIdentityMatching.normalizedGTIN(
                    ProductIdentityMatching.normalizedID(right))
            let theirs = !SnapshotMatcher.matchingSnapshots(
                for: candidate(name: "X", productID: left), candidateURL: url,
                among: [snapshot(name: "Y", gtin: right)]).isEmpty
            XCTAssertEqual(ours, theirs, "GTIN parity failed for \(left) vs \(right)")
        }
    }

    func testNormalizedIDAgreesWithProductMatcher() {
        for raw in ["SKU-1", "sku1", "  ", "0194644090876", "a-b_c 9"] {
            XCTAssertEqual(
                ProductIdentityMatching.normalizedID(raw), ProductMatcher.normalizedID(raw),
                "normalizedID parity failed for '\(raw)'")
        }
        XCTAssertEqual(ProductIdentityMatching.normalizedID(nil), ProductMatcher.normalizedID(nil))
    }

    func testBrandCompatibilityAgreesWithProductMatcher() {
        let brands: [String?] = [nil, "", "  ", "Sony", "sony", "SONY!", "Bose"]
        for left in brands {
            for right in brands {
                XCTAssertEqual(
                    ProductIdentityMatching.brandsCompatible(left, right),
                    ProductMatcher.brandsCompatible(left, right),
                    "brand parity failed for \(String(describing: left)) vs \(String(describing: right))")
            }
        }
    }

    func testNameSimilarityAndThresholdAgreeWithProductMatcher() {
        XCTAssertEqual(ProductIdentityMatching.nameThreshold, ProductMatcher.nameThreshold)
        let names = [
            "Sony WH-1000XM5 Wireless Headphones",
            "Sony WH-1000XM5 Wireless Noise Canceling Headphones",
            "Bose QuietComfort Ultra Earbuds",
            "The New Official Sony Store Headphones",
            "",
        ]
        for left in names {
            for right in names {
                XCTAssertEqual(
                    ProductIdentityMatching.nameSimilarity(left, right),
                    ProductMatcher.nameSimilarity(left, right),
                    accuracy: 0.000001,
                    "name similarity parity failed for '\(left)' vs '\(right)'")
            }
        }
    }
}

/// A refusal page is an EXPECTED outcome for some tier-1 retailers — it is why
/// the candidate list is over-provisioned. Recognizing one has to be cheap and
/// must not fire on an ordinary product page that happens to say "captcha".
final class BotWallDetectionTests: XCTestCase {

    func testBlockedStatusCodesAreBotWalls() {
        for code in [401, 403, 405, 429, 503] {
            XCTAssertTrue(BotWallDetection.isBotWall(statusCode: code, html: "<html></html>"))
        }
    }

    /// 404 is an ordinary miss — the search simply had no such product — and
    /// must not poison the host for the rest of the run.
    func testNotFoundIsNotABotWall() {
        XCTAssertFalse(BotWallDetection.isBotWall(statusCode: 404, html: "<html>no results</html>"))
    }

    func testChallengeInterstitialServedWithTwoHundredIsABotWall() {
        XCTAssertTrue(BotWallDetection.isBotWall(
            statusCode: 200,
            html: "<html><body><h1>Pardon Our Interruption</h1></body></html>"))
        XCTAssertTrue(BotWallDetection.isBotWall(
            statusCode: 200, html: "<html>Please complete the CAPTCHA to continue</html>"))
    }

    func testALargeRealPageIsNotCondemnedByAStrayWord() {
        let padding = String(repeating: "<div>product details</div>", count: 5000)
        XCTAssertGreaterThan(padding.count, 60_000)
        XCTAssertFalse(BotWallDetection.isBotWall(
            statusCode: 200, html: padding + "<p>our captcha policy</p>"))
    }
}
