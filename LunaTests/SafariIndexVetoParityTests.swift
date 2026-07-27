//
//  SafariIndexVetoParityTests.swift
//  LunaTests
//

import LunaHTMLClassification
import WebKit
import XCTest

/// The Safari extension and the ingest pipeline must agree on what an index page
/// is. They used not to: `content.js` has always vetoed listings before offering
/// a pill, while Swift had no equivalent, so pages Safari itself declined to
/// suggest still filled the recents tray and reached the archive reader.
///
/// `ListingPage` is the Swift twin. This runs one fixture set through BOTH — the
/// production `content.js` in a bare `WKWebView`, and `ListingPage` directly — and
/// fails if they disagree, the same guard `ProductPageJSFixtureParityTests` gives
/// the product detector.
@MainActor
final class SafariIndexVetoParityTests: XCTestCase {
    private static let contentScriptSource = resource("LunaSafari/Resources/content.js")
    private static let newsHostsSource = resource("LunaSafari/Resources/news_hosts.generated.js")
    private static let platformHostsSource = resource("LunaSafari/Resources/platform_hosts.generated.js")
    private static let productRulesSource = resource("LunaSafari/Resources/product_rules.generated.js")

    private static func resource(_ relativePath: String) -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)) ?? ""
    }

    override func setUp() {
        super.setUp()
        XCTAssertFalse(Self.contentScriptSource.isEmpty)
        XCTAssertFalse(Self.newsHostsSource.isEmpty)
        XCTAssertFalse(Self.platformHostsSource.isEmpty)
        XCTAssertFalse(Self.productRulesSource.isEmpty)
    }

    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
    }

    private func safariVetoesAsIndex(html: String, urlString: String) -> Bool {
        let expectation = expectation(description: "Safari index veto")
        var outcome: Bool?
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let delegate = LoadDelegate {
            let preludes = [
                Self.newsHostsSource, Self.platformHostsSource,
                Self.productRulesSource, Self.contentScriptSource,
            ]
            func evaluate(_ remaining: ArraySlice<String>) {
                guard let next = remaining.first else {
                    webView.evaluateJavaScript("window.__lunaLooksLikeNonArticleIndex()") {
                        result, error in
                        if let error { XCTFail("index verdict failed: \(error)") }
                        outcome = result as? Bool
                        expectation.fulfill()
                    }
                    return
                }
                webView.evaluateJavaScript(next) { _, error in
                    if let error { XCTFail("prelude failed: \(error)") }
                    evaluate(remaining.dropFirst())
                }
            }
            evaluate(preludes[...])
        }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: URL(string: urlString))
        wait(for: [expectation], timeout: 10)
        withExtendedLifetime(delegate) {}
        return outcome ?? false
    }

    /// The Swift side minus its URL half — `content.js` runs on a loaded document
    /// and has no search-URL shortcut, so only the HTML shapes are comparable.
    /// The URL half is covered by `ListingPageTests`.
    private func swiftVetoesAsIndex(html: String, urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        if ListingPage.hasStructuralListingShape(html: html, baseURL: url) { return true }
        return ListingPage.declaresListingPage(html: html, baseURL: url)
            && ListingPage.headlineLinkCount(html: html, baseURL: url) >= 5
    }

    private func assertParity(
        html: String, urlString: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(
            safariVetoesAsIndex(html: html, urlString: urlString),
            swiftVetoesAsIndex(html: html, urlString: urlString),
            "Safari and Swift disagree about \(urlString)", file: file, line: line)
    }

    // MARK: - Fixtures

    private static func page(_ body: String, head: String = "") -> String {
        "<html><head>\(head)</head><body>\(body)</body></html>"
    }

    private static var storyCards: String {
        (1...12).map {
            """
            <div class="card"><a href="/story-\($0)">\
            A reasonably long headline number \($0) about something newsworthy</a></div>
            """
        }.joined()
    }

    private static var prose: String {
        String(
            repeating: "<p>\(String(repeating: "Real prose in a real paragraph. ", count: 12))</p>",
            count: 8)
    }

    func testIndexVetoMatrix() {
        // A publisher front: declared collection page + a grid of story links.
        assertParity(
            html: Self.page(
                Self.storyCards,
                head: #"<script type="application/ld+json">{"@type":"CollectionPage"}</script>"#),
            urlString: "https://news.example.com/")

        // A section index with no declaration at all — carried by link density.
        assertParity(html: Self.page(Self.storyCards), urlString: "https://news.example.com/world")

        // A teaser feed: four or more sibling <article> cards.
        assertParity(
            html: Self.page((1...5).map {
                "<article><h2>Teaser \($0)</h2><p>a short blurb</p></article>"
            }.joined()),
            urlString: "https://news.example.com/section/tech")

        // A real article with a six-card related rail — the declaration exempts it
        // from both structural shapes, on any host.
        assertParity(
            html: Self.page(
                Self.prose + (1...6).map {
                    "<article><a href=\"/more-\($0)\">Another story you might like, number \($0)</a></article>"
                }.joined(),
                head: #"<meta property="og:type" content="article">"#),
            urlString: "https://blog.example.com/posts/thing")

        // Plain prose, nothing declared.
        assertParity(html: Self.page(Self.prose), urlString: "https://blog.example.com/posts/thing")

        // An article that ALSO declares a listing type still loses: a front page
        // can't slip through on an article claim alone.
        assertParity(
            html: Self.page(
                Self.storyCards,
                head: """
                <meta property="og:type" content="article">
                <script type="application/ld+json">{"@type":"SearchResultsPage"}</script>
                """),
            urlString: "https://news.example.com/search-landing")

        // A landing_homepage declaration (CNN-style) with the link cluster.
        assertParity(
            html: Self.page(
                Self.storyCards,
                head: #"<script type="application/ld+json">{"pageType":"landing_homepage"}</script>"#),
            urlString: "https://news.example.com/")

        // Declared listing but only a couple of substantial links — not enough.
        assertParity(
            html: Self.page(
                Self.prose + #"<a href="/a">One long related headline right here</a>"#,
                head: #"<script type="application/ld+json">{"@type":"CollectionPage"}</script>"#),
            urlString: "https://news.example.com/story")

        // Links that live in site chrome don't count toward the cluster.
        assertParity(
            html: Self.page(
                "<nav>\(Self.storyCards)</nav>" + Self.prose,
                head: #"<script type="application/ld+json">{"@type":"CollectionPage"}</script>"#),
            urlString: "https://news.example.com/story")
    }
}
