//
//  ProductPageJSFixtureParityTests.swift
//  LunaTests
//

import LunaHTMLClassification
import WebKit
import XCTest

/// Runs representative pages through both production implementations. The generated
/// rule artifact prevents data drift; this matrix catches control-flow drift around
/// score composition, listing vetoes, and known-news precedence.
@MainActor
final class ProductPageJSFixtureParityTests: XCTestCase {
    private static let contentScriptSource = resource("LunaSafari/Resources/content.js")
    private static let newsHostsSource = resource("LunaSafari/Resources/news_hosts.generated.js")
    private static let productRulesSource = resource("LunaSafari/Resources/product_rules.generated.js")

    private static func resource(_ relativePath: String) -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent(relativePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    override func setUp() {
        super.setUp()
        XCTAssertFalse(Self.contentScriptSource.isEmpty)
        XCTAssertFalse(Self.newsHostsSource.isEmpty)
        XCTAssertFalse(Self.productRulesSource.isEmpty)
    }

    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
    }

    private func safariLooksLikeProduct(html: String, urlString: String) -> Bool {
        let expectation = expectation(description: "Safari product classification")
        var outcome: Bool?
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let delegate = LoadDelegate {
            webView.evaluateJavaScript(Self.newsHostsSource) { _, newsError in
                if let newsError { XCTFail("news rules failed: \(newsError)") }
                webView.evaluateJavaScript(Self.productRulesSource) { _, productError in
                    if let productError { XCTFail("product rules failed: \(productError)") }
                    webView.evaluateJavaScript(Self.contentScriptSource) { _, scriptError in
                        if let scriptError { XCTFail("content.js failed: \(scriptError)") }
                        webView.evaluateJavaScript("window.__lunaLooksLikeProductPage()") {
                            result, verdictError in
                            if let verdictError { XCTFail("product verdict failed: \(verdictError)") }
                            outcome = result as? Bool
                            expectation.fulfill()
                        }
                    }
                }
            }
        }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: URL(string: urlString))
        wait(for: [expectation], timeout: 10)
        withExtendedLifetime(delegate) {}
        return outcome ?? false
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

    func testSharedProductClassificationMatrix() {
        let structured = """
        <script type="application/ld+json">
        {"@type":"Product","name":"Widget","offers":{"price":"19.99","priceCurrency":"USD"}}
        </script><h1>Widget</h1>
        """
        assertParity(html: structured, urlString: "https://shop.example/products/widget")

        let heuristic = "<h1>Widget</h1><button>Add to cart</button>"
        assertParity(html: heuristic, urlString: "https://shop.example/products/widget")

        let rating = "<h1>Widget</h1><div>Star Rating: 4.8 out of 5</div>"
        assertParity(html: rating, urlString: "https://shop.example/products/widget")

        let weakArticle = "<article><h1>Products in modern life</h1><button>Add to cart</button></article>"
        assertParity(html: weakArticle, urlString: "https://blog.example/2026/products-in-modern-life")

        assertParity(
            html: structured,
            urlString: "https://shop.example/search?q=widget")

        let nestedCurrency = BypassFixtures.html("Products/nested-currency-state.html")
        assertParity(
            html: nestedCurrency,
            urlString: "https://shop.example/au/en/products/P123456-000/00?color=31&size=003")

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
