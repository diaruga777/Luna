//
//  ProductPageJSFixtureParityTests.swift
//  LunaTests
//

import LunaHTMLClassification
import XCTest

/// The end-to-end smoke for `product_rules.generated.js` + `news_hosts.generated.js`:
/// the generated rules really load in WebKit and `content.js`'s product verdict
/// agrees with the Swift `Classifier`/`ProductPageDetector` pair.
///
/// The rule DATA is pinned by `ProductPageRulesJSParityTests` (byte compare) and the
/// per-page semantics by the Swift detector's own tests, so this keeps two pages —
/// a structured Product offer that both sides must accept, and a publisher page
/// whose commerce markup the known-news precedence must beat — instead of running
/// the whole matrix through a browser.
@MainActor
final class ProductPageJSFixtureParityTests: XCTestCase {

    private lazy var js = SafariJSTestHarness(self)

    private func safariLooksLikeProduct(html: String, urlString: String) -> Bool {
        js.load(html: html, urlString: urlString, scripts: [
            SafariJSTestHarness.newsHosts,
            SafariJSTestHarness.productRules,
            SafariJSTestHarness.contentScript,
        ])
        return js.bool("window.__lunaLooksLikeProductPage()")
    }

    private func swiftLooksLikeProduct(html: String, urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        switch Classifier.classify(url: url) {
        case .article, .paywalledArticle, .social, .video, .document:
            return false
        case .product:
            return true
        case .undetermined:
            return ProductPageDetector().detect(urlString: urlString, html: html) != nil
        }
    }

    private func assertParity(
        html: String, urlString: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            safariLooksLikeProduct(html: html, urlString: urlString),
            swiftLooksLikeProduct(html: html, urlString: urlString),
            "Safari and Swift disagree for \(urlString)", file: file, line: line)
    }

    func testGeneratedRulesClassifyInWebKitTheWaySwiftDoes() {
        let structured = """
        <script type="application/ld+json">
        {"@type":"Product","name":"Widget","offers":{"price":"19.99","priceCurrency":"USD"}}
        </script><h1>Widget</h1>
        """
        assertParity(html: structured, urlString: "https://shop.example/products/widget")

        // A publisher page carrying commerce meta — known-news precedence must win
        // on both sides, or Safari offers Track where the app offers Read.
        let publisherCommerce = """
        <meta property="product:price:amount" content="9.99">
        <meta property="product:price:currency" content="USD">
        <article><h1>Subscriber story</h1></article>
        """
        assertParity(
            html: publisherCommerce,
            urlString: "https://www.newyorker.com/culture/story")
    }
}
