//
//  SafariIndexVetoParityTests.swift
//  LunaTests
//

import LunaHTMLClassification
import XCTest

/// The Safari extension and the ingest pipeline must agree on what an index
/// page is. `content.js` has always vetoed listings before offering a pill;
/// without a Swift equivalent, pages Safari itself declined to suggest could
/// still fill the recents tray and reach the archive reader.
///
/// `ListingPage` is the Swift twin. This runs one fixture set through BOTH — the
/// production `content.js` in a bare `WKWebView`, and `ListingPage` directly — and
/// fails if they disagree, the same guard `ProductPageJSFixtureParityTests` gives
/// the product detector.
@MainActor
final class SafariIndexVetoParityTests: XCTestCase {
    private lazy var js = SafariJSTestHarness(self)

    private func safariVetoesAsIndex(html: String, urlString: String) -> Bool {
        js.load(html: html, urlString: urlString, scripts: [
            SafariJSTestHarness.newsHosts,
            SafariJSTestHarness.platformHosts,
            SafariJSTestHarness.productRules,
            SafariJSTestHarness.contentScript,
        ])
        return js.bool("window.__lunaLooksLikeNonArticleIndex()")
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
