//
//  SharedProductMatchingParityTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import XCTest

/// `LunaSafari/SharedProductMatching.swift` is a THIRD hand-written copy of
/// `SnapshotMatcher`/`ProductMatcher`'s identifier precedence, living in a
/// package-free appex — the same situation `SharedSafariURL` is in relative to
/// `LunaSetupStatusStore`. `SafariSetupCelebrationTests` resolves that by
/// pinning literal constants/keys against the extension's SOURCE TEXT rather
/// than compiling it into the test target (LunaSafari isn't set up for dual
/// target membership, and adding it would be exactly the kind of
/// project.pbxproj surgery CLAUDE.md flags as fragile). This test follows the
/// same convention:
///  1. runs a fixture matrix through the REAL `SnapshotMatcher`/`ProductMatcher`
///     pair to pin the EXPECTED per-tier outcomes (also covered directly by
///     `SnapshotMatcherTests`);
///  2. checks the extension's source literally implements the same tiers, in
///     the same precedence order, with the same thresholds/constants, so a
///     future edit to one side that isn't mirrored on the other fails loudly.
final class SharedProductMatchingParityTests: XCTestCase {

    private static func extensionSource(_ relativePath: String) -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)) ?? ""
    }

    private static var matchingSource: String { extensionSource("LunaSafari/SharedProductMatching.swift") }

    // MARK: - The fixture matrix, run through the REAL matcher

    private func snapshot(
        name: String = "Widget", url: String, gtin: String? = nil, mpn: String? = nil,
        sku: String? = nil, retailerItemID: String? = nil, brand: String? = nil
    ) -> ProductSnapshot {
        ProductSnapshot(
            name: name, price: "10", currency: "USD", url: url, host: URL(string: url)!.host!,
            day: "2026-01-01", capturedAt: "2026-01-01T00:00:00Z",
            gtin: gtin, mpn: mpn, sku: sku, retailerItemID: retailerItemID, brand: brand)
    }

    private func candidate(name: String = "Widget", brand: String? = nil, productID: String? = nil) -> ProductInfo {
        ProductInfo(
            name: name, priceAmount: 10, priceCurrency: "USD", imageURL: nil,
            brand: brand, productID: productID)
    }

    /// A single-snapshot pool: with only one candidate to consider, tier
    /// PRECEDENCE (which tier's matches get returned) can't change whether
    /// this one snapshot matches — so "non-empty result" here is exactly the
    /// same question the extension's per-pair boolean answers.
    private func matches(_ candidate: ProductInfo, url: URL, _ snapshot: ProductSnapshot) -> Bool {
        !SnapshotMatcher.matchingSnapshots(for: candidate, candidateURL: url, among: [snapshot]).isEmpty
    }

    func testFixtureMatrixAgreesWithSnapshotMatcher() {
        let url = URL(string: "https://shop.example/p/9")!
        struct Case { let name: String; let expect: Bool; let candidate: ProductInfo; let snapshot: ProductSnapshot }
        let cases: [Case] = [
            Case(name: "gtin match", expect: true,
                 candidate: candidate(productID: "0012345678905"),
                 snapshot: snapshot(url: "https://a.example/p", gtin: "0012345678905")),
            Case(name: "retailerItemID same family", expect: true,
                 candidate: candidate(productID: "B000TEST1"),
                 snapshot: snapshot(url: "https://www.amazon.com/dp/B000TEST1", retailerItemID: "B000TEST1")),
            Case(name: "mpn with compatible brand", expect: true,
                 candidate: candidate(brand: "Acme", productID: "MPN-1"),
                 snapshot: snapshot(url: "https://a.example/p", mpn: "MPN-1", brand: "Acme")),
            Case(name: "mpn with conflicting brand", expect: false,
                 candidate: candidate(brand: "Acme", productID: "MPN-1"),
                 snapshot: snapshot(url: "https://a.example/p", mpn: "MPN-1", brand: "Globex")),
            Case(name: "sku same host", expect: true,
                 candidate: candidate(productID: "SKU-1"),
                 snapshot: snapshot(url: "https://shop.example/p", sku: "SKU-1")),
            // Different name too -- otherwise the fuzzy-name tier (both sides
            // default to "Widget" with no brand set) would rescue this case
            // and mask the sku/host check actually being exercised.
            Case(name: "sku different host", expect: false,
                 candidate: candidate(productID: "SKU-1"),
                 snapshot: snapshot(
                     name: "Unrelated Product Entirely", url: "https://other.example/p", sku: "SKU-1")),
            Case(name: "canonical url with tracking params", expect: true,
                 candidate: candidate(),
                 snapshot: snapshot(url: "https://shop.example/p/9?utm_source=x")),
            Case(name: "fuzzy name with compatible brand", expect: true,
                 candidate: candidate(name: "Acme Wireless Keyboard Pro", brand: "Acme"),
                 snapshot: snapshot(name: "Acme Wireless Keyboard", url: "https://a.example/p", brand: "Acme")),
            Case(name: "unrelated", expect: false,
                 candidate: candidate(name: "Widget"),
                 snapshot: snapshot(name: "Something Else Entirely", url: "https://a.example/p")),
        ]
        for testCase in cases {
            XCTAssertEqual(
                matches(testCase.candidate, url: url, testCase.snapshot), testCase.expect,
                "SnapshotMatcher disagreed with the expected outcome for: \(testCase.name)")
        }
    }

    // MARK: - Structural parity with the extension's copy

    func testTheExtensionImplementsEveryPrecedenceTier() {
        let source = Self.matchingSource
        XCTAssertFalse(source.isEmpty, "LunaSafari/SharedProductMatching.swift not found")
        for marker in [
            "normalizedGTIN", "hostFamilyMatches", "registrableDomain",
            "brandsCompatible", "nameSimilarity", "strippedTrackingURL",
        ] {
            XCTAssertTrue(source.contains(marker), "the extension's matcher has no \"\(marker)\"")
        }
    }

    func testTheExtensionUsesTheSameNameThreshold() {
        XCTAssertTrue(
            Self.matchingSource.contains("nameThreshold = \(ProductMatcher.nameThreshold)"),
            "SharedProductMatching's fuzzy-name threshold has drifted from ProductMatcher.nameThreshold")
    }

    func testTheExtensionUsesTheSameTrackingParamNames() {
        let source = Self.matchingSource
        for token in ["srsltid", "gclid", "utm_", "\"tag\""] {
            XCTAssertTrue(source.contains(token), "the extension's URL stripper has no \"\(token)\"")
        }
    }

    func testTheExtensionUsesTheSameStopWords() {
        // Mirrors ProductMatcher's private stopWords set by literal text --
        // there is no public accessor to compare against directly.
        let stopWords = ["\"the\"", "\"a\"", "\"an\"", "\"and\"", "\"with\"", "\"for\"",
                          "\"new\"", "\"of\"", "\"in\"", "\"to\"", "\"buy\"", "\"shop\"",
                          "\"online\"", "\"official\"", "\"store\""]
        let source = Self.matchingSource
        for word in stopWords {
            XCTAssertTrue(source.contains(word), "the extension's stop-word list is missing \(word)")
        }
    }

    func testTheHandlerAnswersHasHistoryIsTrackedAmountCurrencyDay() {
        let handler = Self.extensionSource("LunaSafari/SafariWebExtensionHandler.swift")
        for field in ["isTracked", "hasHistory", "amount", "currency", "day"] {
            XCTAssertTrue(handler.contains("payload[\"\(field)\"]"),
                          "the native handler never answers \"\(field)\"")
        }
    }
}
