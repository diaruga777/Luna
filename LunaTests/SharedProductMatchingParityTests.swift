//
//  SharedProductMatchingParityTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import LunaPriceCompare
import LunaPriceUI
import XCTest

/// "Is this the same product?" is decided in two places, because it is asked
/// about two different things: `SnapshotMatcher` (LunaPriceUI) answers it for a
/// product being SAVED, over `ProductInfo` and a retrieved pool of observations;
/// `ProductPageMatching` (LunaPriceCompare) answers it for a Safari page's
/// freshly extracted snapshot, against the tracked-product index and other
/// observations. Both run the same identifier precedence, so this suite runs one
/// fixture matrix through each and pins the tiers where they must agree — and
/// the two places they deliberately differ (a page comparison has no fuzzy-name
/// tier; a tracked-entry comparison does).
///
/// The extension's remaining Swift is the message plumbing around them, still a
/// second artifact and still pinned by source text.
final class SharedProductMatchingParityTests: XCTestCase {

    private static func extensionSource(_ relativePath: String) -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)) ?? ""
    }

    // MARK: - The fixture matrix, run through the save-side matcher

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
    /// same question `ProductPageMatching`'s per-pair boolean answers.
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
            // The candidate's own URL decides the retailer FAMILY, so the
            // snapshot has to sit on a sibling host of `url` for tier 2 to be
            // what answers. (A foreign host here would pass on the
            // fuzzy-name tier instead — both sides default to "Widget" —
            // and say nothing about retailer scoping at all.)
            Case(name: "retailerItemID same family", expect: true,
                 candidate: candidate(productID: "B000TEST1"),
                 snapshot: snapshot(url: "https://www.shop.example/dp/B000TEST1", retailerItemID: "B000TEST1")),
            Case(name: "retailerItemID different family", expect: false,
                 candidate: candidate(name: "Unrelated Product Entirely", productID: "B000TEST1"),
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
            Case(name: "sku different host", expect: false,
                 candidate: candidate(productID: "SKU-1"),
                 snapshot: snapshot(
                     name: "Unrelated Product Entirely", url: "https://other.example/p", sku: "SKU-1")),
            Case(name: "canonical url with tracking params", expect: true,
                 candidate: candidate(),
                 snapshot: snapshot(url: "https://shop.example/p/9?utm_source=x")),
            // The name tier, which BOTH sides have and both put last. The
            // extension's copy has always had it; the app's lost it for a
            // while, and that split is what made a Safari observation of an
            // identifier-less page unreachable from a later save.
            //
            // The one deliberate difference is scope: the app's tier requires
            // the same retailer family or the same DECLARED brand, because its
            // pool has to be retrievable from the snapshot index by key
            // (`ProductSnapshotKeys.nameKeys`), while the extension's runs over
            // a compact index it already holds. Both sides agree here — one
            // brand, declared on both.
            Case(name: "similar name, same declared brand", expect: true,
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

    // MARK: - The page matcher, tier by tier

    /// `ProductPageMatching.matches(page:snapshot:)` decides identity between two
    /// observations, which is the same question `SnapshotMatcher`'s identifier
    /// tiers answer for a product being saved — asked in the terms a Safari page
    /// has (keyed identifiers on both sides).
    func testThePageMatcherDecidesEachIdentifierTier() {
        struct Case {
            let name: String
            let expect: Bool
            let page: ProductSnapshot
            let stored: ProductSnapshot
        }
        let cases: [Case] = [
            // Tier 1: a GTIN matches across hosts, and widths are equalised by
            // zero-padding into the GTIN-14 numberspace.
            Case(name: "gtin, declared at different widths", expect: true,
                 page: snapshot(url: "https://shop.example/p/9", gtin: "12345678905"),
                 stored: snapshot(url: "https://a.example/p", gtin: "0012345678905")),
            Case(name: "different gtins", expect: false,
                 page: snapshot(name: "Widget", url: "https://shop.example/p/9", gtin: "1111111111116"),
                 stored: snapshot(
                    name: "Something Else Entirely", url: "https://a.example/p",
                    gtin: "0012345678905")),
            // Tier 2: a retailer's own item id is meaningless off that retailer.
            Case(name: "retailer item id, same family", expect: true,
                 page: snapshot(url: "https://www.shop.example/dp/B000TEST1", retailerItemID: "B000TEST1"),
                 stored: snapshot(url: "https://shop.example/dp/B000TEST1", retailerItemID: "B000TEST1")),
            Case(name: "retailer item id, different family", expect: false,
                 page: snapshot(
                    name: "Widget", url: "https://shop.example/dp/B000TEST1",
                    retailerItemID: "B000TEST1"),
                 stored: snapshot(
                    name: "Something Else Entirely", url: "https://www.amazon.com/dp/B000TEST1",
                    retailerItemID: "B000TEST1")),
            // Tier 3: an MPN is manufacturer-scoped, so a conflicting brand vetoes it.
            Case(name: "mpn with compatible brand", expect: true,
                 page: snapshot(url: "https://shop.example/p/9", mpn: "MPN-1", brand: "Acme"),
                 stored: snapshot(url: "https://a.example/p", mpn: "mpn1", brand: "acme")),
            Case(name: "mpn with conflicting brand", expect: false,
                 page: snapshot(url: "https://shop.example/p/9", mpn: "MPN-1", brand: "Acme"),
                 stored: snapshot(url: "https://a.example/p", mpn: "MPN-1", brand: "Globex")),
            // Tier 4: an SKU means nothing on another host.
            Case(name: "sku on the same host", expect: true,
                 page: snapshot(url: "https://shop.example/p/9", sku: "SKU-1"),
                 stored: snapshot(url: "https://shop.example/p/other", sku: "sku1")),
            Case(name: "sku on another host", expect: false,
                 page: snapshot(name: "Widget", url: "https://shop.example/p/9", sku: "SKU-1"),
                 stored: snapshot(
                    name: "Something Else Entirely", url: "https://other.example/p", sku: "SKU-1")),
            // Tier 5: the same page, seen twice, with tracking parameters that
            // differ between visits.
            Case(name: "canonical url, tracking params stripped", expect: true,
                 page: snapshot(url: "https://shop.example/p/9?utm_source=x"),
                 stored: snapshot(url: "https://shop.example/p/9?gclid=y")),
            // And no tier at all for a similar NAME: this comparison retrieves
            // BY identifier, and a name is not one.
            Case(name: "similar name, same brand, no identifiers", expect: false,
                 page: snapshot(
                    name: "Acme Wireless Keyboard Pro", url: "https://shop.example/p/9",
                    brand: "Acme"),
                 stored: snapshot(
                    name: "Acme Wireless Keyboard", url: "https://a.example/p", brand: "Acme")),
        ]
        for testCase in cases {
            XCTAssertEqual(
                ProductPageMatching.matches(page: testCase.page, snapshot: testCase.stored),
                testCase.expect,
                "the page matcher disagreed for: \(testCase.name)")
        }
    }

    /// A tracked index entry carries ONE flattened `productID` (its kind thrown
    /// away long before it got there) plus its store hosts and URLs, so the page's
    /// KEYED fields are compared against it in the same precedence order. This
    /// comparison DOES end in a fuzzy-name tier: a tracked product is one the user
    /// chose and named, and the index has no keyed identifiers to try instead.
    func testThePageMatcherDecidesEachTrackedEntryTier() {
        func entry(
            name: String = "Widget", brand: String? = nil, productID: String? = nil,
            storeURL: String = "https://tracked.example/p"
        ) -> PriceHistoryIndexEntry {
            PriceHistoryIndexEntry(
                name: name, brand: brand, productID: productID,
                stores: [PriceHistoryIndexEntry.StorePoints(
                    url: storeURL, host: URL(string: storeURL)!.host!, points: [])])
        }
        struct Case {
            let name: String
            let expect: Bool
            let page: ProductSnapshot
            let entry: PriceHistoryIndexEntry
        }
        let cases: [Case] = [
            Case(name: "gtin", expect: true,
                 page: snapshot(url: "https://shop.example/p/9", gtin: "12345678905"),
                 entry: entry(productID: "0012345678905")),
            Case(name: "retailer item id on a tracked store's family", expect: true,
                 page: snapshot(
                    url: "https://www.shop.example/dp/B000TEST1", retailerItemID: "B000TEST1"),
                 entry: entry(productID: "B000TEST1", storeURL: "https://shop.example/dp/B000TEST1")),
            Case(name: "retailer item id on another family", expect: false,
                 page: snapshot(
                    name: "Widget", url: "https://shop.example/dp/B000TEST1",
                    retailerItemID: "B000TEST1"),
                 entry: entry(
                    name: "Something Else Entirely", productID: "B000TEST1",
                    storeURL: "https://www.amazon.com/dp/B000TEST1")),
            Case(name: "mpn with compatible brand", expect: true,
                 page: snapshot(url: "https://shop.example/p/9", mpn: "MPN-1", brand: "Acme"),
                 entry: entry(brand: "acme", productID: "mpn1")),
            Case(name: "mpn with conflicting brand", expect: false,
                 page: snapshot(url: "https://shop.example/p/9", mpn: "MPN-1", brand: "Acme"),
                 entry: entry(brand: "Globex", productID: "MPN-1")),
            Case(name: "sku on a tracked store's own host", expect: true,
                 page: snapshot(url: "https://shop.example/p/9", sku: "SKU-1"),
                 entry: entry(productID: "sku1", storeURL: "https://shop.example/p/other")),
            Case(name: "sku on another host", expect: false,
                 page: snapshot(name: "Widget", url: "https://shop.example/p/9", sku: "SKU-1"),
                 entry: entry(
                    name: "Something Else Entirely", productID: "SKU-1",
                    storeURL: "https://other.example/p")),
            Case(name: "a tracked store url, tracking params stripped", expect: true,
                 page: snapshot(url: "https://shop.example/p/9?utm_source=x"),
                 entry: entry(
                    name: "Something Else Entirely",
                    storeURL: "https://shop.example/p/9?srsltid=z")),
            Case(name: "similar name, same declared brand", expect: true,
                 page: snapshot(
                    name: "Acme Wireless Keyboard Pro", url: "https://shop.example/p/9",
                    brand: "Acme"),
                 entry: entry(name: "Acme Wireless Keyboard", brand: "Acme")),
            Case(name: "nothing in common", expect: false,
                 page: snapshot(name: "Widget", url: "https://shop.example/p/9"),
                 entry: entry(name: "Something Else Entirely")),
        ]
        for testCase in cases {
            XCTAssertEqual(
                ProductPageMatching.matches(page: testCase.page, indexEntry: testCase.entry),
                testCase.expect,
                "the page matcher disagreed about tracked entry: \(testCase.name)")
        }
    }

    // MARK: - The one artifact that cannot link Swift

    /// `content.js` canonicalizes a page's URL before it sends the observation,
    /// and Swift canonicalizes both sides again when it matches. A family the
    /// page strips and Swift keeps would file an observation under a key no
    /// later visit can ask for, so the JS list is read out of the script itself
    /// and every family in it is required to survive a Swift round trip.
    ///
    /// Swift strips one more — Amazon's `tag` — which is why this is a one-way
    /// check rather than an equality.
    func testSwiftStripsEveryTrackingFamilyTheContentScriptDoes() throws {
        let script = Self.extensionSource("LunaSafari/Resources/content.js")
        XCTAssertFalse(script.isEmpty, "LunaSafari/Resources/content.js not found")

        let names = try Self.jsStringArray(named: "TRACKING_QUERY_PARAM_NAMES", in: script)
        let prefixes = try Self.jsStringArray(named: "TRACKING_QUERY_PARAM_PREFIXES", in: script)
        XCTAssertFalse(names.isEmpty)
        XCTAssertFalse(prefixes.isEmpty)

        let page = "https://shop.example/products/widget"
        for name in names {
            XCTAssertEqual(
                ProductSnapshotKeys.strippedTrackingURL("\(page)?\(name)=x"), page,
                "content.js strips \(name) and Swift keeps it")
        }
        for prefix in prefixes {
            XCTAssertEqual(
                ProductSnapshotKeys.strippedTrackingURL("\(page)?\(prefix)source=x"), page,
                "content.js strips \(prefix)* and Swift keeps it")
        }
        // Amazon's affiliate tag, Swift's own addition, and only on Amazon.
        XCTAssertEqual(
            ProductSnapshotKeys.strippedTrackingURL(
                "https://www.amazon.com/dp/B000TEST1?tag=aff"),
            "https://www.amazon.com/dp/B000TEST1")
        XCTAssertEqual(
            ProductSnapshotKeys.strippedTrackingURL("\(page)?tag=aff"), "\(page)?tag=aff")
    }

    /// The string literals of one `var NAME = ["a", "b"];` declaration.
    private static func jsStringArray(named name: String, in script: String) throws -> [String] {
        let pattern = "\(name)\\s*=\\s*\\[([^\\]]*)\\]"
        let range = try XCTUnwrap(
            script.range(of: pattern, options: .regularExpression),
            "content.js declares no \(name)")
        return script[range]
            .split(separator: "\"", omittingEmptySubsequences: false)
            .enumerated()
            // Odd fragments are the quoted values; even ones are the commas.
            .compactMap { $0.offset % 2 == 1 ? String($0.element) : nil }
    }

    func testTheHandlerAnswersHasHistoryIsTrackedAmountCurrencyDay() {
        let handler = Self.extensionSource("LunaSafari/SafariWebExtensionHandler.swift")
        for field in ["isTracked", "hasHistory", "amount", "currency", "day"] {
            XCTAssertTrue(handler.contains("payload[\"\(field)\"]"),
                          "the native handler never answers \"\(field)\"")
        }
    }
}
