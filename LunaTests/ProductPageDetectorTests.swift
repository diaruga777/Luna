//
//  ProductPageDetectorTests.swift
//  LunaTests
//

import LunaHTMLClassification
import XCTest
@testable import Luna

/// Fixture + unit coverage for `ProductPageDetector`: JSON-LD, OpenGraph, and
/// microdata price signals, the Tier-2 heuristic + embedded-JSON price path, plus
/// the pure price/currency parsing primitives. Detection returns a
/// `ProductCandidate`; `staticPrice` is the price found in the static markup.
final class ProductPageDetectorTests: XCTestCase {
    private let detector = ProductPageDetector()

    private func detect(_ fixture: String, url: String) -> ProductCandidate? {
        detector.detect(urlString: url, html: BypassFixtures.html("Products/\(fixture)"))
    }

    // MARK: - Signal coverage

    func testAmazonJSONLD() throws {
        let info = try XCTUnwrap(detect("amazon-jsonld.html", url: "https://www.amazon.com/dp/B09"))
        XCTAssertEqual(info.name, "Anker 715 USB-C Charger (Nano II 65W)")
        XCTAssertEqual(info.staticPrice?.amount, Decimal(string: "45.99"))
        XCTAssertEqual(info.staticPrice?.currency, "USD")
        XCTAssertEqual(info.brand, "Anker")
        XCTAssertEqual(info.productID, "0194644090876")
        XCTAssertEqual(info.imageURL?.absoluteString, "https://m.media-amazon.com/images/I/anker715.jpg")
    }

    func testShopifyOpenGraph() throws {
        let info = try XCTUnwrap(detect("shopify-og.html", url: "https://bellroy.com/products/wallet"))
        XCTAssertEqual(info.name, "The Minimalist Wallet")
        XCTAssertEqual(info.staticPrice?.amount, Decimal(string: "89.00"))
        XCTAssertEqual(info.staticPrice?.currency, "AUD")
        XCTAssertEqual(info.brand, "Bellroy")
        // Protocol-relative og:image resolves against the page URL's scheme.
        XCTAssertEqual(info.imageURL?.absoluteString, "https://cdn.shopify.com/s/files/wallet.jpg")
    }

    func testBestBuyMicrodata() throws {
        let info = try XCTUnwrap(detect("bestbuy-microdata.html", url: "https://www.bestbuy.com/site/6505725.p"))
        XCTAssertEqual(info.name, "Sony WH-1000XM5 Wireless Noise Canceling Headphones")
        XCTAssertEqual(info.staticPrice?.amount, Decimal(string: "399.99"))
        XCTAssertEqual(info.staticPrice?.currency, "USD")
        XCTAssertEqual(info.productID, "6505725")
    }

    func testGenericJSONLDGraphWithAggregateOfferAndEUPrice() throws {
        let info = try XCTUnwrap(detect("generic-jsonld-graph.html", url: "https://coffeegear.example/p/v60"))
        XCTAssertEqual(info.name, "Hario V60 Ceramic Coffee Dripper 02 White")
        XCTAssertEqual(info.staticPrice?.amount, Decimal(string: "23.50"))
        XCTAssertEqual(info.staticPrice?.currency, "EUR")
        XCTAssertEqual(info.brand, "Hario")
        XCTAssertEqual(info.productID, "VDC-02W")
    }

    // MARK: - Keyed identifiers

    /// The flattened `productID` says WHAT the id is but not WHICH KIND, and only
    /// a GTIN travels between retailers — so detection keeps the kinds apart in
    /// `identifiers` for the alternative-seller comparison to match on.
    func testJSONLDKeepsGTINAndSKUApart() throws {
        let info = try XCTUnwrap(detect("amazon-jsonld.html", url: "https://www.amazon.com/dp/B09"))
        XCTAssertEqual(info.identifiers.gtin, "0194644090876")
        XCTAssertEqual(info.identifiers.sku, "A2663")
        XCTAssertEqual(info.identifiers.brand, "Anker")
        XCTAssertNil(info.identifiers.mpn)
        // The flattened value is unchanged — nothing migrated.
        XCTAssertEqual(info.productID, "0194644090876")
    }

    func testMicrodataSKUIsNotPromotedToAGTIN() throws {
        let info = try XCTUnwrap(detect(
            "bestbuy-microdata.html", url: "https://www.bestbuy.com/site/6505725.p"))
        XCTAssertEqual(info.identifiers.sku, "6505725")
        XCTAssertNil(info.identifiers.gtin, "a retailer SKU is not a cross-host identifier")
        XCTAssertEqual(info.identifiers.brand, "Sony")
        XCTAssertFalse(info.identifiers.hasCrossHostIdentifier)
    }

    func testJSONLDMPNIsKeptAsAnMPN() throws {
        let info = try XCTUnwrap(detect(
            "generic-jsonld-graph.html", url: "https://coffeegear.example/p/v60"))
        XCTAssertEqual(info.identifiers.mpn, "VDC-02W")
        XCTAssertNil(info.identifiers.gtin)
        XCTAssertEqual(info.identifiers.brand, "Hario")
        XCTAssertTrue(info.identifiers.hasCrossHostIdentifier, "an MPN + brand is cross-host")
    }

    func testArticleWithoutPriceIsNotAProduct() {
        XCTAssertNil(detect("article-no-price.html", url: "https://news.example/grid"))
    }

    func testEmptyHTMLIsNil() {
        XCTAssertNil(detector.detect(urlString: "https://x.example", html: ""))
    }

    // MARK: - Heuristic detection + embedded-JSON price (Tier 2)

    /// The real Bunnings product page that triggered the bug report: NO structured
    /// price data (no JSON-LD / og:price / itemprop=price / visible "$"), so Tier 1
    /// finds nothing. Heuristic detection must still identify it as a product (add to
    /// cart + rating + retail URL + embedded price = 4 strong signals) and recover
    /// 99 AUD from the __NEXT_DATA__ blob.
    func testBunningsNextDataHeuristicProductWith99AUD() throws {
        let url = "https://www.bunnings.com.au/ryobi-18v-one-25-30cm-cordless-line-trimmer-tool-only_p0208315"
        let info = try XCTUnwrap(detect("bunnings-nextdata.html", url: url))
        XCTAssertEqual(info.name, "Ryobi 18V ONE+ 25/30cm Cordless Line Trimmer - Tool Only")
        XCTAssertEqual(info.staticPrice?.amount, Decimal(99),
                       "The Bunnings price lives statically in __NEXT_DATA__ — recovered with no WebView.")
        XCTAssertEqual(info.staticPrice?.currency, "AUD")
        XCTAssertEqual(
            info.imageURL?.absoluteString,
            "https://media.bunnings.com.au/api/public/content/3982166a37204b0b887bbeb6e6c54547?v=f2c8dc14&t=w1200")
    }

    /// The same fixture must be classified as a PRODUCT, not fall through to the
    /// article/paywall pipeline — the regression the bug report describes.
    func testBunningsIsDetectedAsProductNotArticle() {
        let url = "https://www.bunnings.com.au/ryobi-18v-one-25-30cm-cordless-line-trimmer-tool-only_p0208315"
        XCTAssertNotNil(detect("bunnings-nextdata.html", url: url),
                        "A retail product page must win the product path, not the article/paywall path.")
    }

    /// A normal news article with the same retail-ish URL shape but none of the
    /// product signals must NOT be a product (heuristic doesn't over-fire).
    func testNewsArticleIsNotAProductEvenWithProductishURL() {
        // article-no-price.html has og:type=article, no add-to-cart, no rating, no
        // embedded price. Even at a /products/-shaped URL that's a single weak
        // signal — below the ≥2 threshold.
        XCTAssertNil(detect("article-no-price.html", url: "https://news.example/products/grid-story"))
    }

    func testEmbeddedPriceFromNextDataValueAndCurrencyIso() {
        let node: [String: Any] = [
            "currencyIso": "AUD", "formattedValue": "$99.00",
            "priceAvailable": true, "priceType": "FROM", "value": 99,
        ]
        let price = try? XCTUnwrap(ProductPageDetector.firstPrice(in: node))
        XCTAssertEqual(price?.amount, Decimal(99))
        XCTAssertEqual(price?.currency, "AUD")
    }

    func testEmbeddedPriceIgnoresValuesWithoutPriceContext() {
        // A bare {value: 5} with no price-context key is NOT a price.
        let node: [String: Any] = ["value": 5, "label": "page 5"]
        XCTAssertNil(ProductPageDetector.firstPrice(in: node))
    }

    /// The real amazon.com.au /dp/ page that "spun forever": NO structured price
    /// node, so Tier 1 finds nothing — but the price IS in the static markup
    /// (`"priceAmount":39.99` / `"displayPrice":"$39.99"` / `.a-offscreen`). The
    /// page must be detected as a product (add to cart + /dp/ URL) AND its price
    /// recovered as 39.99 AUD via the FAST static path (no WebView). No currency is
    /// declared in the markup, so AUD comes from the amazon.com.au TLD.
    func testAmazonDPStaticPriceIsAUDViaTLD() throws {
        let url = "https://www.amazon.com.au/Mrisata-Rotating-Electric-Machine-Conveyor/dp/B0CWRSYTTK"
        let html = BypassFixtures.html("Products/amazon-dp.html")
        let candidate = try XCTUnwrap(
            detector.detect(urlString: url, html: html),
            "An Amazon /dp/ page with add-to-cart must win the product path.")
        XCTAssertTrue(candidate.name.contains("Sushi"))

        let price = try XCTUnwrap(
            detector.staticPrice(urlString: url, html: html),
            "The Amazon price lives statically in the markup — recovered with no WebView.")
        XCTAssertEqual(price.amount, Decimal(string: "39.99"))
        XCTAssertEqual(price.currency, "AUD")
    }

    func testAmazonStaticPriceUSDForDotComBareDollar() {
        let html = #"<html><body><span class="a-offscreen">$12.50</span></body></html>"#
        let price = ProductPageDetector.amazonStaticPrice(
            html: html, baseURL: URL(string: "https://www.amazon.com/dp/B000000"))
        XCTAssertEqual(price?.amount, Decimal(string: "12.50"))
        XCTAssertEqual(price?.currency, "USD")
    }

    func testAmazonStaticPriceNilForNonAmazonHost() {
        let html = #"<html><body><span class="a-offscreen">$12.50</span></body></html>"#
        XCTAssertNil(ProductPageDetector.amazonStaticPrice(
            html: html, baseURL: URL(string: "https://www.notamazon.com/dp/B000000")))
    }

    func testEmbeddedPriceFromSellPriceShape() {
        let node: [String: Any] = ["product": ["sellPrice": "19.99", "priceCurrency": "GBP"]]
        let price = ProductPageDetector.firstPrice(in: node)
        XCTAssertEqual(price?.amount, Decimal(string: "19.99"))
        XCTAssertEqual(price?.currency, "GBP")
    }

    func testEmbeddedPriceWithNestedCurrencyObject() throws {
        let info = try XCTUnwrap(detect(
            "nested-currency-state.html",
            url: "https://shop.example/au/en/products/P123456-000/00?color=31&size=003"))
        XCTAssertEqual(info.staticPrice?.amount, Decimal(string: "49.9"))
        XCTAssertEqual(info.staticPrice?.currency, "AUD")
        XCTAssertEqual(info.name, "Pleated Travel Skort")
    }

    func testNestedCurrencyObjectPrimitive() {
        let node: [String: Any] = [
            "currency": ["code": "AUD", "symbol": "$"],
            "value": 49.9,
        ]
        XCTAssertEqual(
            ProductPageDetector.firstPrice(in: node),
            ProductPrice(amount: Decimal(string: "49.9")!, currency: "AUD"))
    }

    // MARK: - Determinism (the bug: same URL → different result each paste)

    /// Detection + static-price extraction over the Bunnings fixture must yield the
    /// IDENTICAL product candidate (name, price, currency) on every run. The original
    /// bug was a non-deterministic outcome — the same page produced price tracking
    /// only sometimes — rooted in hash-seed-randomized dictionary traversal. Running
    /// the pure detector many times must never flip the result.
    func testBunningsDetectionIsDeterministicAcrossManyRuns() {
        let url = "https://www.bunnings.com.au/ryobi-18v-one-25-30cm-cordless-line-trimmer-tool-only_p0208315"
        let html = BypassFixtures.html("Products/bunnings-nextdata.html")
        var results = Set<String>()
        for _ in 0..<200 {
            let candidate = detector.detect(urlString: url, html: html)
            let staticPrice = detector.staticPrice(urlString: url, html: html)
            let signature = "\(candidate?.name ?? "nil")|"
                + "\(candidate?.staticPrice?.amount.description ?? "nil")|"
                + "\(candidate?.staticPrice?.currency ?? "nil")|"
                + "\(staticPrice?.amount.description ?? "nil")|\(staticPrice?.currency ?? "nil")"
            results.insert(signature)
        }
        XCTAssertEqual(results.count, 1, "Detection must be a pure deterministic function of the page.")
        XCTAssertEqual(results.first,
                       "Ryobi 18V ONE+ 25/30cm Cordless Line Trimmer - Tool Only|99|AUD|99|AUD")
    }

    /// When a JSON tree carries MORE THAN ONE price-bearing object, `firstPrice` must
    /// always pick the same one — chosen by sorted-key traversal, not the process's
    /// randomized dictionary order. Two distinct prices under sibling keys ("a" < "z")
    /// must resolve to "a"'s price every run.
    func testFirstPriceIsOrderStableWithMultiplePriceObjects() {
        let node: [String: Any] = [
            "zStore": ["priceCurrency": "USD", "price": 200],
            "aStore": ["priceCurrency": "USD", "price": 100],
        ]
        var amounts = Set<String>()
        for _ in 0..<200 {
            if let price = ProductPageDetector.firstPrice(in: node) {
                amounts.insert(price.amount.description)
            }
        }
        XCTAssertEqual(amounts, ["100"],
                       "The sorted-first key ('aStore') must win deterministically every run.")
    }

    /// `firstProductNode` (JSON-LD walk) must likewise pick the same Product node when
    /// a `@graph` carries several, regardless of dictionary hash order.
    func testJSONLDProductSelectionIsOrderStable() {
        // Two Product nodes reachable under sibling keys; sorted traversal of the
        // wrapper's keys ("graphA" < "graphB") must always reach graphA's product.
        let html = """
        <html><head><script type="application/ld+json">
        {"graphB":{"@type":"Product","name":"B","offers":{"price":"2.00","priceCurrency":"USD"}},
         "graphA":{"@type":"Product","name":"A","offers":{"price":"1.00","priceCurrency":"USD"}}}
        </script></head><body></body></html>
        """
        var signatures = Set<String>()
        for _ in 0..<200 {
            let candidate = detector.detect(urlString: "https://x.example/dp/B000000", html: html)
            signatures.insert("\(candidate?.name ?? "nil")|\(candidate?.staticPrice?.amount.description ?? "nil")")
        }
        XCTAssertEqual(signatures.count, 1, "JSON-LD product selection must be order-stable.")
    }

    func testProductURLPatterns() {
        XCTAssertTrue(ProductPageDetector.urlLooksLikeProduct(URL(string: "https://x.com/foo_p0208315")))
        XCTAssertTrue(ProductPageDetector.urlLooksLikeProduct(URL(string: "https://amazon.com/dp/B09ABCDE")))
        XCTAssertTrue(ProductPageDetector.urlLooksLikeProduct(URL(string: "https://shop.com/products/wallet")))
        XCTAssertFalse(ProductPageDetector.urlLooksLikeProduct(URL(string: "https://news.com/2024/story")))
        XCTAssertFalse(ProductPageDetector.urlLooksLikeProduct(URL(string: "https://news.com/")))
    }

    // MARK: - Multi-product listing veto (search / category grids)

    /// The bug report: an Amazon search-results page (`/s?k=…`) shows several
    /// products, each with its own "Add to cart" button and star rating.
    /// Without the listing-URL veto, those per-card signals score ≥2 in Tier
    /// 2 and mint a "Track in Luna" pill on a page with no single primary
    /// product.
    func testAmazonSearchResultsPageIsNotAProduct() {
        let html = BypassFixtures.html("Products/amazon-search.html")
        XCTAssertNil(detector.detect(urlString: "https://www.amazon.com/s?k=wireless+headphones", html: html),
                     "A search-results grid lists many products at equal primacy — never a product page.")
    }

    /// The exact same search-results markup at a single-product `/dp/` URL WOULD
    /// classify (add-to-cart + rating + product URL) — proving the veto keys on the
    /// listing URL, not on stripping the page of its retail signals.
    func testSearchMarkupAtProductURLStillClassifies() {
        let html = BypassFixtures.html("Products/amazon-search.html")
        XCTAssertNotNil(detector.detect(urlString: "https://www.amazon.com/dp/B09XS7JWHH", html: html),
                        "At a /dp/ URL the same retail furniture is a legitimate single product.")
    }

    func testMultiProductListingURLShapes() {
        func isListing(_ s: String) -> Bool { ProductPageDetector.urlIsMultiProductListing(URL(string: s)) }
        // Search / browse / category / deals grids.
        XCTAssertTrue(isListing("https://www.amazon.com/s?k=wireless+headphones"))
        XCTAssertTrue(isListing("https://www.amazon.com/s?k=laptop"))
        XCTAssertTrue(isListing("https://www.amazon.com.au/b?node=4851917051"))
        XCTAssertTrue(isListing("https://www.amazon.com/gp/bestsellers/electronics"))
        XCTAssertTrue(isListing("https://www.ebay.com/sch/i.html?_nkw=camera"))
        XCTAssertTrue(isListing("https://shop.example/collections/all"))
        XCTAssertTrue(isListing("https://store.example/search?query=boots"))
        // Single-product pages are NOT listings, even with a listing-ish token elsewhere.
        XCTAssertFalse(isListing("https://www.amazon.com/dp/B09XS7JWHH"))
        XCTAssertFalse(isListing("https://www.amazon.com/Sony-Headphones/dp/B09XS7JWHH?ref=sr_1"))
        XCTAssertFalse(isListing("https://bellroy.com/products/wallet"))
        XCTAssertFalse(isListing("https://www.bunnings.com.au/ryobi-trimmer_p0208315"))
        XCTAssertFalse(isListing("https://news.example/2024/some-story"))
    }

    /// A search URL must not slip through Tier 1 either: a listing that emits per-card
    /// structured offers still describes its grid items, not one primary product.
    func testStructuredDataOnSearchURLIsVetoed() {
        let html = """
        <html><head><script type="application/ld+json">
        {"@type":"Product","name":"A","offers":{"@type":"Offer","price":"9.99","priceCurrency":"USD"}}
        </script></head><body></body></html>
        """
        XCTAssertNil(detector.detect(urlString: "https://shop.example/search?q=widgets", html: html),
                     "A search URL vetoes even a structured Product offer (it's a grid item).")
        XCTAssertNotNil(detector.detect(urlString: "https://shop.example/products/widget", html: html),
                        "The same structured offer at a product URL still classifies.")
    }

    // MARK: - Price parsing

    func testParsePriceUSStyle() {
        XCTAssertEqual(ProductPageDetector.parsePrice("$1,234.56"), Decimal(string: "1234.56"))
        XCTAssertEqual(ProductPageDetector.parsePrice("45.99"), Decimal(string: "45.99"))
        XCTAssertEqual(ProductPageDetector.parsePrice("Now 19.00 USD"), Decimal(string: "19.00"))
    }

    func testParsePriceEUStyle() {
        XCTAssertEqual(ProductPageDetector.parsePrice("1.234,56"), Decimal(string: "1234.56"))
        XCTAssertEqual(ProductPageDetector.parsePrice("23,50 €"), Decimal(string: "23.50"))
    }

    func testParsePriceThousandsCommaOnly() {
        XCTAssertEqual(ProductPageDetector.parsePrice("1,299"), Decimal(string: "1299"))
    }

    func testParsePriceRejectsNonNumeric() {
        XCTAssertNil(ProductPageDetector.parsePrice(""))
        XCTAssertNil(ProductPageDetector.parsePrice("free"))
    }

    // MARK: - Currency normalization

    func testNormalizeCurrency() {
        XCTAssertEqual(ProductPageDetector.normalizeCurrency("usd"), "USD")
        XCTAssertEqual(ProductPageDetector.normalizeCurrency("$"), "USD")
        XCTAssertEqual(ProductPageDetector.normalizeCurrency("£"), "GBP")
        XCTAssertEqual(ProductPageDetector.normalizeCurrency("€"), "EUR")
        XCTAssertNil(ProductPageDetector.normalizeCurrency(""))
        XCTAssertNil(ProductPageDetector.normalizeCurrency("dollars"))
    }
}
