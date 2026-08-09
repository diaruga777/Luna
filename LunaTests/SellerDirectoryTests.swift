//
//  SellerDirectoryTests.swift
//  LunaTests
//

import LunaPriceCompare
import XCTest

/// Pins the SHIPPED `seller-directory.json` — this is the file the fan-out's
/// whole seller universe comes from, and a hand-edited entry with a broken
/// template or an invented category would simply make one retailer silently
/// unreachable. Also covers the two-context `{query}` substitution, which is the
/// one place a URL can be built wrong without anything throwing.
final class SellerDirectoryTests: XCTestCase {

    private func bundledDirectory() throws -> SellerDirectory {
        try SellerDirectory.bundled()
    }

    // MARK: - The real file

    func testBundledDirectoryLoads() throws {
        let directory = try bundledDirectory()
        XCTAssertEqual(directory.version, 1)
        XCTAssertGreaterThan(directory.sellers.count, 100)
    }

    func testBundledDirectoryIsValid() throws {
        let problems = try bundledDirectory().validate()
        XCTAssertEqual(problems, [], "seller-directory.json has structural problems")
    }

    func testBundledDirectoryCoversTheEnglishSpeakingRegions() throws {
        let regions = Set(try bundledDirectory().regions)
        for expected in ["US", "GB", "CA", "AU", "NZ", "IE"] {
            XCTAssertTrue(regions.contains(expected), "missing region \(expected)")
        }
    }

    /// Every region needs enough tier-1 mass merchants to fill a full-profile
    /// candidate list even when the product suggests no category at all.
    func testEveryRegionHasGeneralMerchants() throws {
        let directory = try bundledDirectory()
        for region in directory.regions {
            let general = directory.sellers(inRegion: region)
                .filter { $0.categories.contains(SellerCategory.general.rawValue) }
            XCTAssertGreaterThanOrEqual(
                general.count, 3, "region \(region) has only \(general.count) general merchants")
        }
    }

    func testSellerLookupIsByRetailerFamily() throws {
        let directory = try bundledDirectory()
        XCTAssertEqual(directory.seller(forHost: "www.amazon.com")?.id, "amazon-us")
        XCTAssertEqual(directory.seller(forHost: "smile.amazon.com")?.id, "amazon-us")
        XCTAssertNil(directory.seller(forHost: "not-a-real-shop.example"))
    }

    /// Five AU appliance/electronics sellers added after a live JB Hi-Fi /
    /// Bing Lee fan-out found the AU directory too thin to answer with
    /// anything but the source itself (`claudedocs/price-comparison.md`).
    /// Each entry's shape was independently measured, live, 2026-08-09:
    /// `binglee-au`'s search 200s with real product links for a GTIN query;
    /// `appliancesonline-au` (Angular bundle), `costco-au` (Spartacus/SAP
    /// Commerce SPA — every path serves the same empty shell) and
    /// `betta-au` (a Handlebars-templated Shopify search widget,
    /// `{{ product.handle }}` literally unrendered in the served markup) are
    /// all live 200s with zero static product links; `retravision-au`'s
    /// entire site — including its homepage — sits behind a Cloudflare JS
    /// challenge that a plain fetch cannot pass, so it is unverified.
    func testTheFiveNewAUApplianceSellersAreShapedAsMeasured() throws {
        let directory = try bundledDirectory()
        let byID = Dictionary(uniqueKeysWithValues: directory.sellers.map { ($0.id, $0) })
        for id in ["binglee-au", "appliancesonline-au", "retravision-au", "costco-au", "betta-au"] {
            XCTAssertNotNil(byID[id], "missing \(id)")
        }
        XCTAssertEqual(byID["binglee-au"]?.region, "AU")
        XCTAssertEqual(byID["binglee-au"]?.acceptsGTIN, true)
        XCTAssertFalse(byID["binglee-au"]?.searchRequiresRendering ?? true)

        for id in ["appliancesonline-au", "costco-au", "betta-au"] {
            XCTAssertTrue(
                byID[id]?.searchRequiresRendering ?? false, "\(id) is a measured JS shell")
        }
        XCTAssertFalse(
            byID["retravision-au"]?.searchRequiresRendering ?? true,
            "retravision is bot-walled, not client-rendered — a different failure mode")
        XCTAssertFalse(byID["retravision-au"]?.verified ?? true, "its shape could not be confirmed live")

        for id in ["binglee-au", "appliancesonline-au", "retravision-au", "costco-au", "betta-au"] {
            let categories = Set(byID[id]?.categories ?? [])
            XCTAssertTrue(
                categories.contains(SellerCategory.appliances.rawValue)
                    || categories.contains(SellerCategory.electronics.rawValue)
                    || categories.contains(SellerCategory.general.rawValue),
                "\(id) should be reachable by an appliance/electronics product")
        }
    }

    // MARK: - Validation catches what it claims to

    private func seller(
        id: String = "s1", domain: String = "shop.example",
        searchURL: String = "https://shop.example/search?q={query}",
        categories: [String] = ["general"], tier: Int = 1, region: String = "US"
    ) -> Seller {
        Seller(id: id, name: "Shop", region: region, domain: domain, searchURL: searchURL,
               acceptsGTIN: true, marketplace: false, categories: categories,
               tier: tier, verified: true)
    }

    func testValidationRejectsDuplicateIDsMissingPlaceholderAndUnknownCategory() {
        let directory = SellerDirectory(version: 1, sellers: [
            seller(id: "dupe"),
            seller(id: "dupe"),
            seller(id: "noplaceholder", searchURL: "https://shop.example/search?q=fixed"),
            seller(id: "insecure", searchURL: "http://shop.example/search?q={query}"),
            seller(id: "badcategory", categories: ["not-a-category"]),
            seller(id: "badtier", tier: 9),
            seller(id: "offdomain", searchURL: "https://elsewhere.example/s?q={query}"),
        ])
        let problems = directory.validate().joined(separator: "\n")
        XCTAssertTrue(problems.contains("dupe: duplicate id"), problems)
        XCTAssertTrue(problems.contains("noplaceholder: searchURL must contain exactly one"), problems)
        XCTAssertTrue(problems.contains("insecure: searchURL must be https"), problems)
        XCTAssertTrue(problems.contains("badcategory: 'not-a-category'"), problems)
        XCTAssertTrue(problems.contains("badtier: tier must be 1…3"), problems)
        XCTAssertTrue(problems.contains("offdomain: searchURL host"), problems)
    }

    // MARK: - Query substitution

    /// A `+` means "space" only inside a query string. In a path segment it is a
    /// literal plus, so the same escaping in both places would silently search
    /// for the wrong thing on the 11 path-template retailers.
    func testQuerySubstitutionEscapesByPlaceholderContext() throws {
        let queryTemplate = seller(searchURL: "https://shop.example/search?q={query}")
        XCTAssertEqual(
            queryTemplate.searchRequestURL(forQuery: "sony wh-1000xm5")?.absoluteString,
            "https://shop.example/search?q=sony+wh-1000xm5")

        let pathTemplate = seller(searchURL: "https://shop.example/s/{query}")
        XCTAssertEqual(
            pathTemplate.searchRequestURL(forQuery: "sony wh-1000xm5")?.absoluteString,
            "https://shop.example/s/sony%20wh-1000xm5")
    }

    func testQuerySubstitutionEscapesReservedCharacters() throws {
        let template = seller(searchURL: "https://shop.example/search?q={query}&sort=price")
        let url = try XCTUnwrap(template.searchRequestURL(forQuery: "tools & bits?/#x"))
        XCTAssertEqual(
            url.absoluteString,
            "https://shop.example/search?q=tools+%26+bits%3F%2F%23x&sort=price")
        // The trailing parameter survives — the product name cannot break out.
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "sort" })?.value, "price")
    }

    func testEmptyQueryYieldsNoURL() {
        XCTAssertNil(seller().searchRequestURL(forQuery: "   "))
    }

    /// Every shipped template must survive a realistic query, including the
    /// path-context ones.
    func testEveryBundledTemplateBuildsAURL() throws {
        for seller in try bundledDirectory().sellers {
            XCTAssertNotNil(
                seller.searchRequestURL(forQuery: "sony wh-1000xm5 headphones"),
                "\(seller.id) failed to build a search URL")
        }
    }
}
