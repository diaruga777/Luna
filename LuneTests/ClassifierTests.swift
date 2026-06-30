//
//  ClassifierTests.swift
//  LuneTests
//

import LuneHTMLClassification
import LuneURLClassification
import XCTest
@testable import Lune

/// Data-driven coverage of `Classifier.classify`: the deterministic `KnownSite`
/// table over the named sites (shops / news / social, positives + negatives), the
/// product false-positive guard, and the HTML heuristic phase. Pure — no network,
/// no WebView.
final class ClassifierTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    private func fixture(_ name: String) -> String { BypassFixtures.html(name) }
    private func productFixture(_ name: String) -> String { BypassFixtures.html("Products/\(name)") }

    // MARK: - Deterministic table: shops

    func testKnownShopHostsClassifyAsProduct() {
        let shops = [
            "https://www.amazon.com/dp/B09ABCDEF",
            "https://www.amazon.com.au/dp/B09ABCDEF",
            "https://www.amazon.co.uk/dp/B09ABCDEF",
            "https://www.target.com/p/thing/-/A-123",
            "https://www.walmart.com/ip/thing/123",
            "https://www.bestbuy.com/site/6505725.p",
            "https://www.ebay.com/itm/123456",
            "https://www.etsy.com/listing/123/thing",
            "https://www.bunnings.com.au/thing_p0208315",
        ]
        for shop in shops {
            XCTAssertEqual(Classifier.classify(url: url(shop)), .product(.knownShopHost), "for \(shop)")
        }
    }

    func testEveryAmazonStorefrontClassifiesAsProduct() {
        for host in AmazonPriceRule.storefrontHosts {
            let storefront = "https://www.\(host)/dp/B09ABCDEF"
            XCTAssertEqual(
                Classifier.classify(url: url(storefront)), .product(.knownShopHost), "for \(host)")
        }
    }

    func testGoogleShoppingPagesClassifyAsProduct() {
        // Both the search-results shopping grid and a specific product's offers page
        // (the canonical form a shared `share.google` product link resolves to) route
        // straight to product extraction — URL-only, so they never reach the article
        // path. Distinguished by query params the host+path table can't express.
        let shopping = [
            "https://www.google.com/search?q=vacuum&tbm=shop",
            "https://www.google.com/search?q=vacuum&udm=28&shopmd=1",
            "https://www.google.com/search?ibp=oshop&q=Ryobi&prds=productid:17194174350050566621",
        ]
        for page in shopping {
            XCTAssertEqual(Classifier.classify(url: url(page)), .product(.knownShopHost), "for \(page)")
        }
        // An ordinary Google web search is NOT a shopping page.
        XCTAssertEqual(
            Classifier.classify(url: url("https://www.google.com/search?q=vacuum")), .undetermined)
    }

    // MARK: - Deterministic table: news

    func testHardPaywallNewsClassifiesAsPaywalledHardHost() {
        let hard = [
            "https://www.nytimes.com/2026/01/01/story.html",
            "https://www.washingtonpost.com/2026/story",
            "https://www.wsj.com/articles/story",
            "https://www.ft.com/content/abc",
            "https://www.economist.com/story",
            "https://www.smh.com.au/national/story",
            "https://www.theage.com.au/national/story",
            "https://www.bloomberg.com/news/story",
        ]
        for site in hard {
            XCTAssertEqual(Classifier.classify(url: url(site)), .paywalledArticle(hardHost: true), "for \(site)")
        }
    }

    func testFreeNewsClassifiesAsArticleFastPath() {
        let free = [
            "https://www.theguardian.com/world/story",
            "https://www.bbc.com/news/story",
            "https://www.reuters.com/world/story",
            "https://apnews.com/article/story",
            "https://en.wikipedia.org/wiki/Swift",
        ]
        for site in free {
            XCTAssertEqual(Classifier.classify(url: url(site)), .article, "for \(site)")
        }
    }

    // MARK: - Deterministic table: social / video / audio (FIRST branch)

    func testPlatformURLsClassifyBeforeAnythingElse() {
        XCTAssertEqual(
            Classifier.classify(url: url("https://www.youtube.com/watch?v=dQw4w9WgXcQ")),
            .video(.youtube, itemID: "dQw4w9WgXcQ"))
        XCTAssertEqual(
            Classifier.classify(url: url("https://x.com/jack/status/20")),
            .social(.x, itemID: "20"))
        XCTAssertEqual(
            Classifier.classify(url: url("https://open.spotify.com/track/abc")),
            .audio(.music, .spotify, itemID: "abc"))
        XCTAssertEqual(
            Classifier.classify(url: url("https://open.spotify.com/episode/xyz")),
            .audio(.podcast, .spotify, itemID: "xyz"))
        XCTAssertEqual(
            Classifier.classify(url: url("https://www.tiktok.com/@u/video/7212345678901234567")),
            .video(.tiktok, itemID: "7212345678901234567"))
    }

    /// A YouTube channel page (no video id) is NOT a video — it falls through the
    /// platform row to undetermined (URL-only), never text-extracted-as-article by
    /// the table alone.
    func testYouTubeChannelPageIsNotVideo() {
        XCTAssertEqual(Classifier.classify(url: url("https://www.youtube.com/@channel")), .undetermined)
    }

    // MARK: - URL-only table miss → undetermined

    func testUnknownHostURLOnlyIsUndetermined() {
        XCTAssertEqual(Classifier.classify(url: url("https://some-unknown-blog.example/post/1")), .undetermined)
    }

    // MARK: - Heuristic phase (table miss + HTML)

    func testHeuristicStructuredProductFromUnknownShop() {
        let kind = Classifier.classify(
            url: url("https://coffeegear.example/p/v60"),
            html: productFixture("generic-jsonld-graph.html"))
        XCTAssertEqual(kind, .product(.structuredData))
    }

    func testHeuristicOpenGraphProductFromUnknownShop() {
        let kind = Classifier.classify(
            url: url("https://bellroy.example/products/wallet"),
            html: productFixture("shopify-og.html"))
        XCTAssertEqual(kind, .product(.structuredData))
    }

    /// Regression guard (audit P6): a news article that merely MENTIONS shopping
    /// (a stray "addToCart" / rating with no structured product or price) must NOT
    /// be misclassified a product.
    func testNewsArticleWithStrayAddToCartIsNotProduct() {
        let kind = Classifier.classify(
            url: url("https://news.example/the-new-rules-of-online-shopping"),
            html: fixture("classifier-article-stray-addtocart.html"))
        XCTAssertNotEqual(kind, .product(.structuredData))
        if case .product = kind { XCTFail("stray addToCart must not classify as product, got \(kind)") }
    }

    func testHeuristicPaywallLockedHTML() {
        let kind = Classifier.classify(
            url: url("https://unknown-news.example/investigation"),
            html: fixture("classifier-paywall-locked.html"))
        XCTAssertEqual(kind, .paywalledArticle(hardHost: false))
    }

    func testHeuristicArticleWithoutSignalsIsUndetermined() {
        let kind = Classifier.classify(
            url: url("https://news.example/grid"),
            html: productFixture("article-no-price.html"))
        XCTAssertEqual(kind, .undetermined)
    }

    // MARK: - Document flag wins

    func testDocumentTypeAlwaysWins() {
        // Even on a known shop host, an explicit document type wins.
        XCTAssertEqual(
            Classifier.classify(url: url("https://www.amazon.com/dp/B09"), documentType: "pdf"),
            .document(type: "pdf"))
    }

    // MARK: - Parity: same input → same kind regardless of caller

    func testClassificationIsPureAndStableAcrossCalls() {
        let inputs = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.nytimes.com/2026/01/01/story.html",
            "https://www.amazon.com/dp/B09ABCDEF",
            "https://www.theguardian.com/world/story",
        ]
        for input in inputs {
            let first = Classifier.classify(url: url(input))
            let second = Classifier.classify(url: url(input))
            XCTAssertEqual(first, second, "classification must be deterministic for \(input)")
        }
    }
}
