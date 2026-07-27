//
//  ListingPageTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import XCTest

/// `ListingPage` is the Swift twin of the Safari extension's index veto. Its HTML
/// half is held against the production `content.js` by
/// `SafariIndexVetoParityTests`; these are the URL half (which the extension has
/// no equivalent for) and the false-positive guards, which matter more than the
/// hits: a wrong veto silently drops a real save.
final class ListingPageTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    // MARK: - Search-results URLs

    func testSearchResultsURLsAreRecognizedFromTheURLAlone() {
        for candidate in [
            "https://www.google.com/search?q=swift+listing",
            "https://www.google.co.uk/search?q=x&hl=en",
            "https://www.bing.com/search?q=hello",
            "https://duckduckgo.com/?q=swift",
            "https://example.com/search/climate",
            "https://example.com/en/search?query=climate",
            "https://old.reddit.com/search?q=x",
        ] {
            XCTAssertTrue(
                ListingPage.isSearchResultsURL(url(candidate)),
                "\(candidate) should read as search results")
        }
    }

    /// The expensive direction. A search veto that fires on an article URL drops
    /// the save with no trace, so each of these is a specific near-miss.
    func testOrdinaryURLsAreNotSearchResults() {
        for candidate in [
            "https://www.nytimes.com/2026/07/28/us/politics/a-story.html",
            // A leading `s` segment is a search on Amazon and a publication on
            // Medium — which is why the commerce listing table is kept out of here.
            "https://medium.com/s/a-publication/a-real-essay-abc123",
            "https://example.com/",
            "https://example.com/blog/how-we-search-for-meaning",
            // A search-shaped param with no value isn't a search.
            "https://example.com/?q=",
            // A search param deep in an article URL is a highlight/anchor, not a
            // results page — only a bare root carries the search on its own.
            "https://example.com/blog/post?q=highlight",
        ] {
            XCTAssertFalse(
                ListingPage.isSearchResultsURL(url(candidate)),
                "\(candidate) should not read as search results")
        }
    }

    func testSiteRootRequiresAnEmptyPathAndQuery() {
        XCTAssertTrue(ListingPage.isSiteRoot(url("https://example.com")))
        XCTAssertTrue(ListingPage.isSiteRoot(url("https://example.com/")))
        XCTAssertFalse(ListingPage.isSiteRoot(url("https://example.com/?ref=nav")))
        XCTAssertFalse(ListingPage.isSiteRoot(url("https://example.com/story")))
    }

    // MARK: - The combined verdict

    private func page(_ body: String, head: String = "") -> String {
        "<html><head>\(head)</head><body>\(body)</body></html>"
    }

    private var storyCards: String {
        (1...12).map {
            """
            <div class="card"><a href="/story-\($0)">\
            A reasonably long headline number \($0) about something newsworthy</a></div>
            """
        }.joined()
    }

    private var prose: String {
        String(
            repeating: "<p>\(String(repeating: "Real prose in a real paragraph. ", count: 12))</p>",
            count: 8)
    }

    func testSearchURLIsVetoedWithNoHTMLAtAll() {
        XCTAssertTrue(ListingPage.isNonContentPage(
            url: url("https://www.google.com/search?q=luna"), html: nil))
    }

    /// A page we could not fetch keeps every recovery route it has — a bot-blocked
    /// article must still reach the browser/archive tier.
    func testAnUnfetchablePageIsNeverVetoed() {
        XCTAssertFalse(ListingPage.isNonContentPage(
            url: url("https://www.reuters.com/world/some-story-2026-07-14/"), html: nil))
    }

    func testPublisherFrontPageIsNonContent() {
        XCTAssertTrue(ListingPage.isNonContentPage(
            url: url("https://news.example.com/"), html: page(storyCards)))
    }

    func testHomepageWithNoContentIsNonContent() {
        let google = page(
            #"<a href="/gmail">Gmail</a> <a href="/images">Images</a>"#,
            head: "<title>Google</title>")
        XCTAssertTrue(ListingPage.isNonContentPage(
            url: url("https://www.google.com/"), html: google))
    }

    func testDeclaredArticleWithACardRailIsContent() {
        let rail = (1...6).map {
            "<article><a href=\"/more-\($0)\">Another story you might like, number \($0)</a></article>"
        }.joined()
        XCTAssertFalse(ListingPage.isNonContentPage(
            url: url("https://blog.example.com/posts/thing"),
            html: page(prose + rail, head: #"<meta property="og:type" content="article">"#)))
    }

    func testUndeclaredProseArticleIsContent() {
        XCTAssertFalse(ListingPage.isNonContentPage(
            url: url("https://blog.example.com/posts/thing"), html: page(prose)))
    }

    /// JSON-LD `NewsArticle` counts as a declaration just as `og:type` does.
    func testJSONLDNewsArticleExemptsAStructurallyListingPage() {
        let feed = (1...5).map { "<article><h2>Teaser \($0)</h2></article>" }.joined()
        let declared = page(
            feed,
            head: #"<script type="application/ld+json">{"@type":"NewsArticle"}</script>"#)
        XCTAssertFalse(ListingPage.hasStructuralListingShape(html: declared))
        XCTAssertTrue(ListingPage.hasStructuralListingShape(html: page(feed)))
    }

    func testHeadlineLinkCountIgnoresChromeAndShortLinks() {
        let chrome = page("<nav>\(storyCards)</nav>")
        XCTAssertEqual(ListingPage.headlineLinkCount(html: chrome), 0)

        let shortLinks = page((1...9).map { "<a href=\"/x\($0)\">Home</a>" }.joined())
        XCTAssertEqual(ListingPage.headlineLinkCount(html: shortLinks), 0)

        XCTAssertEqual(ListingPage.headlineLinkCount(html: page(storyCards)), 5)
    }

    func testDeclaredListingAloneIsNotEnoughWithoutTheLinkCluster() {
        let story = page(
            prose + #"<a href="/a">One long related headline right here</a>"#,
            head: #"<script type="application/ld+json">{"@type":"CollectionPage"}</script>"#)
        XCTAssertTrue(ListingPage.declaresListingPage(html: story))
        XCTAssertFalse(ListingPage.isNonContentPage(
            url: url("https://news.example.com/story"), html: story))
    }

    // MARK: - The failure reason it produces

    func testNotContentIsNeitherRetriedNorRescued() {
        XCTAssertFalse(SaveFailureReason.notContent.isWorthRetrying)
        XCTAssertFalse(SaveFailureReason.notContent.isWorthRescuing)
        XCTAssertTrue(SaveFailureReason.notReadable.isWorthRescuing)
        XCTAssertFalse(SaveFailureReason.notContent.headline.isEmpty)
        XCTAssertNotNil(SaveFailureReason.notContent.suggestion)
    }
}
