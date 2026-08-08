//
//  SellerCandidateSelectorTests.swift
//  LunaTests
//

import LunaModels
import LunaPriceCompare
import XCTest

/// The ranking that decides which dozen retailers (out of 200-odd) get asked.
/// It runs identically in the app, the extensions and the Safari appex, so it
/// has to be a pure, total, deterministic function of its input — a reshuffle
/// between surfaces would make the same product answer differently depending on
/// where it was saved.
final class SellerCandidateSelectorTests: XCTestCase {

    private func seller(
        _ id: String, tier: Int = 1, categories: [String] = ["general"],
        acceptsGTIN: Bool? = nil, marketplace: Bool = false, verified: Bool = false,
        region: String = "US", domain: String? = nil
    ) -> Seller {
        Seller(
            id: id, name: id.capitalized, region: region, domain: domain ?? "\(id).example",
            searchURL: "https://\(domain ?? "\(id).example")/search?q={query}",
            acceptsGTIN: acceptsGTIN, marketplace: marketplace, categories: categories,
            tier: tier, verified: verified)
    }

    private func directory(_ sellers: [Seller]) -> SellerDirectory {
        SellerDirectory(version: 1, sellers: sellers)
    }

    private func input(
        sourceHost: String = "source.example", identifiers: ProductIdentifiers = .init(),
        productName: String = "Widget", categoryHints: [String] = [],
        excludedHosts: [String] = [], region: String = "US", limit: Int = 12
    ) -> SellerCandidateSelector.Input {
        SellerCandidateSelector.Input(
            sourceHost: sourceHost, identifiers: identifiers, productName: productName,
            categoryHints: categoryHints, excludedHosts: excludedHosts,
            region: region, limit: limit)
    }

    // MARK: - Ordering

    func testOrdersByScoreThenTierThenID() {
        let subject = directory([
            seller("charlie", tier: 3),
            seller("alpha", tier: 1),
            seller("bravo", tier: 1),
            seller("delta", tier: 2),
        ])
        let ranked = SellerCandidateSelector.select(input(), in: subject)
        XCTAssertEqual(ranked.map(\.seller.id), ["alpha", "bravo", "delta", "charlie"])
    }

    /// Equal-scoring sellers must not swap places between runs — the id tiebreak
    /// is the only thing standing between this and a directory-order dependency.
    func testOrderingIsIndependentOfDirectoryOrder() {
        let sellers = [
            seller("alpha"), seller("bravo"), seller("charlie"), seller("delta"),
        ]
        let forward = SellerCandidateSelector.select(input(), in: directory(sellers))
        let backward = SellerCandidateSelector.select(input(), in: directory(sellers.reversed()))
        XCTAssertEqual(forward.map(\.seller.id), backward.map(\.seller.id))
    }

    func testRepeatedSelectionIsIdentical() throws {
        let subject = try SellerDirectory.bundled()
        let query = input(
            sourceHost: "www.bestbuy.com",
            identifiers: ProductIdentifiers(gtin: "0194644090876", brand: "Sony"),
            productName: "Sony WH-1000XM5 Wireless Headphones")
        let first = SellerCandidateSelector.select(query, in: subject).map(\.seller.id)
        for _ in 0..<5 {
            XCTAssertEqual(SellerCandidateSelector.select(query, in: subject).map(\.seller.id), first)
        }
    }

    // MARK: - Bounds

    func testRespectsTheCandidateLimit() {
        let subject = directory((0..<30).map { seller(String(format: "s%02d", $0)) })
        XCTAssertEqual(SellerCandidateSelector.select(input(limit: 12), in: subject).count, 12)
        XCTAssertEqual(SellerCandidateSelector.select(input(limit: 6), in: subject).count, 6)
        XCTAssertTrue(SellerCandidateSelector.select(input(limit: 0), in: subject).isEmpty)
    }

    /// The constrained (Safari) list must be a PREFIX of the full one, or the
    /// two surfaces would disagree about which retailer is most promising.
    func testConstrainedListIsAPrefixOfTheFullList() throws {
        let subject = try SellerDirectory.bundled()
        let full = SellerCandidateSelector.select(input(limit: 12), in: subject).map(\.seller.id)
        let constrained = SellerCandidateSelector.select(input(limit: 6), in: subject).map(\.seller.id)
        XCTAssertEqual(Array(full.prefix(6)), constrained)
    }

    // MARK: - Exclusions

    func testExcludesTheSourceAndExistingStoresByFamily() {
        let subject = directory([
            seller("alpha", domain: "alpha.example"),
            seller("bravo", domain: "bravo.example"),
            seller("charlie", domain: "charlie.example"),
        ])
        let ranked = SellerCandidateSelector.select(
            input(sourceHost: "www.alpha.example", excludedHosts: ["shop.bravo.example"]),
            in: subject)
        XCTAssertEqual(ranked.map(\.seller.id), ["charlie"])
    }

    func testOnlyTheRequestedRegionIsEligible() {
        let subject = directory([
            seller("us1", region: "US"), seller("gb1", region: "GB"), seller("gb2", region: "GB"),
        ])
        XCTAssertEqual(
            Set(SellerCandidateSelector.select(input(region: "GB"), in: subject).map(\.seller.id)),
            ["gb1", "gb2"])
    }

    // MARK: - Scoring weights

    func testTierDominatesAndCategoryOverlapIsCapped() {
        let uncapped = SellerCandidateSelector.score(
            seller("x", tier: 2, categories: ["electronics", "computers", "gaming"]),
            categories: ["electronics", "computers", "gaming"], hasGTIN: false)
        // tier 2 (18) + capped overlap (24) — three overlaps do not beat two.
        XCTAssertEqual(uncapped, 42)
        let twoOverlaps = SellerCandidateSelector.score(
            seller("y", tier: 2, categories: ["electronics", "computers"]),
            categories: ["electronics", "computers", "gaming"], hasGTIN: false)
        XCTAssertEqual(twoOverlaps, 42)
    }

    func testGTINBonusOnlyAppliesWhenWeHaveAGTIN() {
        let gtinSeller = seller("x", tier: 1, acceptsGTIN: true)
        XCTAssertEqual(
            SellerCandidateSelector.score(gtinSeller, categories: [], hasGTIN: true), 40)
        XCTAssertEqual(
            SellerCandidateSelector.score(gtinSeller, categories: [], hasGTIN: false), 30)
    }

    /// Third-party listings retitle the same product freely, so a name-only
    /// search on a marketplace is the noisiest thing the fan-out can do.
    func testMarketplacesArePenalizedWithoutAGTIN() {
        let market = seller("m", tier: 1, marketplace: true)
        XCTAssertEqual(SellerCandidateSelector.score(market, categories: [], hasGTIN: false), 22)
        XCTAssertEqual(SellerCandidateSelector.score(market, categories: [], hasGTIN: true), 30)
    }

    func testVerifiedTemplatesGetASmallBonus() {
        XCTAssertEqual(
            SellerCandidateSelector.score(seller("v", verified: true), categories: [], hasGTIN: false)
                - SellerCandidateSelector.score(seller("u"), categories: [], hasGTIN: false),
            4)
    }

    // MARK: - Category inference

    func testUncategorizedProductsSearchMassMerchantsOnly() {
        let subject = directory([
            seller("mass", categories: ["general"]),
            seller("specialist", categories: ["jewelry"]),
        ])
        let ranked = SellerCandidateSelector.select(
            input(productName: "Zorblax 3000"), in: subject)
        XCTAssertEqual(ranked.map(\.seller.id), ["mass"])
    }

    func testCategoryHintsPullSpecialistsIntoTheRanking() {
        let subject = directory([
            seller("mass", tier: 1, categories: ["general"]),
            seller("specialist", tier: 2, categories: ["electronics"]),
        ])
        let ranked = SellerCandidateSelector.select(
            input(productName: "Wireless Headphones", categoryHints: ["Electronics > Audio"]),
            in: subject)
        // tier 2 + one overlap (18+12) beats tier 1 with none (30)? No — it ties,
        // and the tier tiebreak keeps the household name first. Both are asked.
        XCTAssertEqual(Set(ranked.map(\.seller.id)), ["mass", "specialist"])
        XCTAssertEqual(ranked.first?.seller.id, "mass")
    }

    func testKeywordInferenceRespectsWordBoundaries() {
        XCTAssertTrue(SellerCategoryInference.categories(
            hints: [], productName: "Dog Bed Large").contains(SellerCategory.pets.rawValue))
        XCTAssertFalse(SellerCategoryInference.categories(
            hints: [], productName: "Dogma: A Novel").contains(SellerCategory.pets.rawValue))
    }

    func testSourceRetailerCategoriesJoinTheInferenceButGeneralDoesNot() {
        let inferred = SellerCategoryInference.categories(
            hints: [], productName: "Zorblax 3000",
            sourceCategories: ["general", "jewelry"])
        XCTAssertEqual(inferred, [SellerCategory.jewelry.rawValue])
    }

    // MARK: - Region resolution

    func testRegionComesFromTheSourceRetailerFirst() throws {
        let subject = try SellerDirectory.bundled()
        XCTAssertEqual(
            SellerCandidateSelector.resolveRegion(
                sourceHost: "www.johnlewis.com", directory: subject, localeRegion: "US"),
            "GB", "a UK storefront is a UK shopping trip wherever the phone is")
    }

    func testUnknownSourceFallsBackToLocaleThenUS() {
        let subject = directory([seller("us1", region: "US"), seller("au1", region: "AU")])
        XCTAssertEqual(
            SellerCandidateSelector.resolveRegion(
                sourceHost: "unknown.example", directory: subject, localeRegion: "AU"),
            "AU")
        XCTAssertEqual(
            SellerCandidateSelector.resolveRegion(
                sourceHost: "unknown.example", directory: subject, localeRegion: "FR"),
            "US", "a region with no storefronts falls back rather than returning nothing")
        XCTAssertEqual(
            SellerCandidateSelector.resolveRegion(
                sourceHost: "unknown.example", directory: subject, localeRegion: nil),
            "US")
    }

    // MARK: - Per-seller query

    func testGTINQueryOnlyForSellersKnownToAcceptIt() {
        let identifiers = ProductIdentifiers(gtin: "0194644090876")
        XCTAssertEqual(
            SellerCandidateSelector.query(
                for: seller("a", acceptsGTIN: true), identifiers: identifiers,
                productName: "Sony Headphones"),
            "0194644090876")
        XCTAssertEqual(
            SellerCandidateSelector.query(
                for: seller("b", acceptsGTIN: nil), identifiers: identifiers,
                productName: "Sony Headphones"),
            "Sony Headphones", "unknown GTIN support is not a licence to search by digits")
        XCTAssertEqual(
            SellerCandidateSelector.query(
                for: seller("c", acceptsGTIN: true),
                identifiers: ProductIdentifiers(gtin: "ISBN-080442957X"),
                productName: "Sony Headphones"),
            "Sony Headphones", "a non-numeric id is not a GTIN search")
    }
}
