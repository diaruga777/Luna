//
//  LeanProductPageParserTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaPriceCompare
import XCTest

/// The regex-only page reader the comparison engine uses where SwiftSoup cannot
/// go (the Safari appex, under its ~80MB ceiling). It reads strictly less than
/// `ProductPageDetector` — structured data only, nothing heuristic — so the
/// interesting cases are what it must still get right, and what it must refuse.
final class LeanProductPageParserTests: XCTestCase {

    private let pageURL = URL(string: "https://shop.example/products/widget")!

    private func page(_ html: String, url: URL? = nil) -> ParsedProductPage? {
        LeanProductPageParser.parse(html: html, url: url ?? pageURL)
    }

    // MARK: - JSON-LD

    func testJSONLDYieldsKeyedIdentifiersPriceAndImage() throws {
        let html = """
        <html><head><script type="application/ld+json">
        {"@context":"https://schema.org","@type":"Product",
         "name":"Sony WH-1000XM5","gtin13":"0194644090876","mpn":"WH1000XM5B","sku":"A-42",
         "brand":{"@type":"Brand","name":"Sony"},
         "image":["https://cdn.example/xm5.jpg"],
         "offers":{"@type":"Offer","price":"329.99","priceCurrency":"USD"}}
        </script></head><body></body></html>
        """
        let parsed = try XCTUnwrap(page(html))
        XCTAssertEqual(parsed.name, "Sony WH-1000XM5")
        XCTAssertEqual(parsed.price, Decimal(string: "329.99"))
        XCTAssertEqual(parsed.currency, "USD")
        XCTAssertEqual(parsed.identifiers.gtin, "0194644090876")
        XCTAssertEqual(parsed.identifiers.mpn, "WH1000XM5B")
        XCTAssertEqual(parsed.identifiers.sku, "A-42")
        XCTAssertEqual(parsed.identifiers.brand, "Sony")
        XCTAssertEqual(parsed.imageURL?.absoluteString, "https://cdn.example/xm5.jpg")
        XCTAssertTrue(parsed.hasUsablePrice)
    }

    func testJSONLDGraphResolvesTheProductNodeAndAggregateOffer() throws {
        let html = """
        <script type="application/ld+json">
        {"@graph":[{"@type":"BreadcrumbList"},
          {"@type":"Product","name":"Hario V60","mpn":"VDC-02W",
           "offers":{"@type":"AggregateOffer","lowPrice":23.5,"priceCurrency":"EUR"}}]}
        </script>
        """
        let parsed = try XCTUnwrap(page(html))
        XCTAssertEqual(parsed.name, "Hario V60")
        XCTAssertEqual(parsed.price, Decimal(string: "23.5"))
        XCTAssertEqual(parsed.currency, "EUR")
        XCTAssertEqual(parsed.identifiers.mpn, "VDC-02W")
    }

    /// A `@graph` with more than one Product must always resolve to the same
    /// node — dictionary order is hash-seeded per process, so sorted-key walking
    /// is what makes the Safari appex and the app agree.
    func testProductNodeResolutionIsStableAcrossRuns() throws {
        let html = """
        <script type="application/ld+json">
        {"zeta":{"@type":"Product","name":"Zeta","offers":{"price":"2","priceCurrency":"USD"}},
         "alpha":{"@type":"Product","name":"Alpha","offers":{"price":"1","priceCurrency":"USD"}}}
        </script>
        """
        let names = (0..<20).map { _ in page(html)?.name }
        XCTAssertEqual(Set(names.compactMap { $0 }).count, 1, "non-deterministic node choice")
        XCTAssertEqual(names.first ?? nil, "Alpha", "sorted-key walk visits 'alpha' first")
    }

    // MARK: - OpenGraph / microdata fallbacks

    func testOpenGraphPriceAndTitle() throws {
        let html = """
        <html><head>
        <meta property="og:title" content="The Minimalist Wallet">
        <meta property="product:price:amount" content="89.00">
        <meta property="product:price:currency" content="AUD">
        <meta property="og:image" content="//cdn.example/wallet.jpg">
        <meta property="product:brand" content="Bellroy">
        </head></html>
        """
        let parsed = try XCTUnwrap(page(html))
        XCTAssertEqual(parsed.name, "The Minimalist Wallet")
        XCTAssertEqual(parsed.price, Decimal(string: "89.00"))
        XCTAssertEqual(parsed.currency, "AUD")
        XCTAssertEqual(parsed.identifiers.brand, "Bellroy")
        XCTAssertEqual(parsed.imageURL?.absoluteString, "https://cdn.example/wallet.jpg")
    }

    func testMicrodataIdentifiersAndPrice() throws {
        let html = """
        <html><head><title>Widget | Shop</title></head><body>
        <div itemscope itemtype="https://schema.org/Product">
          <meta itemprop="gtin13" content="0123456789012">
          <meta itemprop="sku" content="XYZ-1">
          <meta itemprop="priceCurrency" content="GBP">
          <span itemprop="price" content="19.99">£19.99</span>
        </div></body></html>
        """
        let parsed = try XCTUnwrap(page(html))
        XCTAssertEqual(parsed.name, "Widget | Shop")
        XCTAssertEqual(parsed.price, Decimal(string: "19.99"))
        XCTAssertEqual(parsed.currency, "GBP")
        XCTAssertEqual(parsed.identifiers.gtin, "0123456789012")
        XCTAssertEqual(parsed.identifiers.sku, "XYZ-1")
    }

    func testFormattedAmountsWithSymbolsAndSeparators() throws {
        let usFormatted = try XCTUnwrap(page("""
            <meta property="og:title" content="TV">
            <meta property="og:price:amount" content="$1,299.00">
            <meta property="og:price:currency" content="USD">
            """))
        XCTAssertEqual(usFormatted.price, Decimal(string: "1299.00"))

        let euFormatted = try XCTUnwrap(page("""
            <meta property="og:title" content="TV">
            <meta property="og:price:amount" content="1.299,00">
            <meta property="og:price:currency" content="EUR">
            """))
        XCTAssertEqual(euFormatted.price, Decimal(string: "1299.00"))
    }

    // MARK: - Refusals

    /// A page whose price only exists after client-side rendering is not a
    /// failure — it is a candidate the fan-out skips in favour of the next one.
    func testPageWithNoStructuredPriceHasNoUsablePrice() throws {
        let parsed = try XCTUnwrap(page("<html><head><title>Some Shop</title></head></html>"))
        XCTAssertNil(parsed.price)
        XCTAssertFalse(parsed.hasUsablePrice)
    }

    func testPageWithNoNameAtAllIsNotAProduct() {
        XCTAssertNil(page("<html><body><p>nothing here</p></body></html>"))
    }

    func testZeroPriceIsNotUsable() throws {
        let parsed = try XCTUnwrap(page("""
            <meta property="og:title" content="Free thing">
            <meta property="og:price:amount" content="0">
            <meta property="og:price:currency" content="USD">
            """))
        XCTAssertFalse(parsed.hasUsablePrice)
    }

    // MARK: - Search-results link extraction

    private let searchURL = URL(string: "https://shop.example/search?q=widget")!

    func testExtractsSameHostProductLinksInDocumentOrderAndDeduplicates() {
        let html = """
        <a href="/cart">Cart</a>
        <a href="https://other.example/products/impostor">Elsewhere</a>
        <a href="/products/widget-blue?utm_source=search">Widget Blue</a>
        <a href="/products/widget-blue">Widget Blue again</a>
        <a href="/products/widget-red">Widget Red</a>
        <a href="/search?q=more">More results</a>
        <a href="/products/widget-green">Widget Green</a>
        """
        let links = LeanProductPageParser.productLinks(
            inSearchHTML: html, baseURL: searchURL, limit: 3)
        XCTAssertEqual(links.map(\.absoluteString), [
            "https://shop.example/products/widget-blue",
            "https://shop.example/products/widget-red",
            "https://shop.example/products/widget-green",
        ])
    }

    func testListingLinksAreNeverFollowed() {
        let html = """
        <a href="/search?q=widget2">Search</a>
        <a href="/category/widgets">Category</a>
        <a href="/collections/all">Collection</a>
        """
        XCTAssertTrue(LeanProductPageParser.productLinks(
            inSearchHTML: html, baseURL: searchURL, limit: 5).isEmpty)
    }

    /// Slug-shaped product URLs (Target's `/-/A-`, Walmart's `/ip/`) are not in
    /// the shared numeric-id pattern table, but they are the shapes real search
    /// results use — so they are accepted after the strict patterns miss.
    func testSlugShapedProductURLsAreAcceptedAfterStrictPatterns() {
        let html = """
        <a href="/ip/sony-headphones/12345">Walmart style</a>
        <a href="/p/sony-wh-1000xm5/-/A-84920312">Target style</a>
        <a href="/dp/B09XS7JWHH">Amazon style</a>
        """
        let links = LeanProductPageParser.productLinks(
            inSearchHTML: html, baseURL: searchURL, limit: 5)
        XCTAssertEqual(links.first?.path, "/dp/B09XS7JWHH", "strict patterns rank first")
        XCTAssertEqual(links.count, 3)
    }

    func testLimitOfZeroReturnsNothing() {
        XCTAssertTrue(LeanProductPageParser.productLinks(
            inSearchHTML: "<a href=\"/products/x\">x</a>", baseURL: searchURL, limit: 0).isEmpty)
    }
}

/// The lean module hand-copies `ProductPageRules` and the two URL predicates
/// because it cannot link SwiftSoup. This pins the copy to the original: a rule
/// added on one side and not the other is exactly the drift that would make the
/// Safari extension and the app disagree about what a product URL is.
final class LeanProductURLParityTests: XCTestCase {

    func testRuleTablesMatchProductPageRules() {
        XCTAssertEqual(LeanProductURLRules.productPathPatterns, ProductPageRules.productPathPatterns)
        XCTAssertEqual(
            LeanProductURLRules.listingFirstPathSegments, ProductPageRules.listingFirstPathSegments)
        XCTAssertEqual(
            LeanProductURLRules.listingTwoSegmentPaths, ProductPageRules.listingTwoSegmentPaths)
        XCTAssertEqual(
            LeanProductURLRules.searchQueryParameterNames, ProductPageRules.searchQueryParameterNames)
    }

    func testPredicatesAgreeAcrossAMatrixOfRealURLShapes() {
        let urls = [
            "https://www.amazon.com/dp/B09XS7JWHH",
            "https://www.amazon.com/gp/product/B09XS7JWHH",
            "https://www.amazon.com/s?k=headphones",
            "https://www.amazon.com/gp/bestsellers/electronics",
            "https://www.ebay.com/itm/123456789",
            "https://www.ebay.com/sch/i.html?_nkw=widget",
            "https://bellroy.com/products/wallet",
            "https://www.bunnings.com.au/drill_p0208315",
            "https://www.bestbuy.com/site/6505725.p",
            "https://shop.example/p/12345",
            "https://shop.example/category/widgets",
            "https://shop.example/collections/all",
            "https://shop.example/search?query=widget",
            "https://shop.example/",
            "https://shop.example/about",
        ]
        for string in urls {
            let url = URL(string: string)!
            XCTAssertEqual(
                LeanProductURLRules.looksLikeProduct(url),
                ProductPageDetector.urlLooksLikeProduct(url),
                "looksLikeProduct disagreed for \(string)")
            XCTAssertEqual(
                LeanProductURLRules.isMultiProductListing(url),
                ProductPageDetector.urlIsMultiProductListing(url),
                "isMultiProductListing disagreed for \(string)")
        }
    }

    func testNilURLsAgree() {
        XCTAssertEqual(
            LeanProductURLRules.looksLikeProduct(nil), ProductPageDetector.urlLooksLikeProduct(nil))
        XCTAssertEqual(
            LeanProductURLRules.isMultiProductListing(nil),
            ProductPageDetector.urlIsMultiProductListing(nil))
    }
}
