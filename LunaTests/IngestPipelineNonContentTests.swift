//
//  IngestPipelineNonContentTests.swift
//  LunaTests
//

import LunaArticleIngest
import LunaFetch
import LunaHTMLClassification
import LunaIngest
import LunaModels
import LunaPriceIngest
import XCTest

/// The reported pair of bugs, pinned end-to-end through the real pipeline.
///
/// Safari showed no Luna pill on these pages, yet the app both offered them in
/// the recents tray and, on a direct share, sent them to the archive.today
/// CAPTCHA reader. Two causes: `.paywalled` (→ `.needsArchive`) needed nothing
/// but a `<title>`, and Swift had no index veto at all.
///
/// The "do not become too aggressive" half is tested just as hard: a genuine
/// paywall must still park, and a bot-blocked article must still reach the
/// browser tier.
final class IngestPipelineNonContentTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // These fixtures exercise the sibling apps' retained native composition.
        savedURLPolicy = URLBehaviorPolicy.pluginsOnly
        savedPluginStage = IngestPipeline.pluginStage
        URLBehaviorPolicy.pluginsOnly = false
        IngestPipeline.pluginStage = nil
    }

    override func tearDown() {
        URLBehaviorPolicy.pluginsOnly = savedURLPolicy
        IngestPipeline.pluginStage = savedPluginStage
        super.tearDown()
    }

    private var savedURLPolicy = false
    private var savedPluginStage: (any PluginIngestStaging)?


    private func url(_ string: String) -> URL { URL(string: string)! }

    private func run(
        _ url: URL, html: String?, fetcher: MockArticleFetcher
    ) async -> Outcome {
        if let html { fetcher.htmlByURL[url.absoluteString] = html }
        return await IngestPipeline.process(
            IngestInput(url: url, source: .shareSheet),
            timeout: 5,
            fetcher: fetcher,
            articleProcessor: ArticleIngestProcessor(),
            productProcessor: ProductIngestProcessor())
    }

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

    /// Long enough to clear `ArticleContent.readableBodyThreshold`, so the veto is
    /// the only thing standing between an index page and a real `.article`.
    private var readableProse: String {
        String(
            repeating: "<p>\(String(repeating: "Real prose in a real paragraph. ", count: 20))</p>",
            count: 12)
    }

    // MARK: - Bug 1: every titled page parked for archive.is

    func testHomepageWithATitleAndNoContentFailsInsteadOfParkingForArchive() async {
        let outcome = await run(
            url("https://www.google.com/"),
            html: page(
                #"<a href="/gmail">Gmail</a> <a href="/images">Images</a>"#,
                head: "<title>Google</title>"),
            fetcher: MockArticleFetcher())

        XCTAssertEqual(outcome, .failed(.notContent))
    }

    /// The narrower form of the same bug: an ordinary page that isn't an index
    /// at all, is simply unreadable, and carries a title. A title alone must
    /// not be enough to park it for archive.
    func testUnreadableOrdinaryPageWithATitleFailsInsteadOfParkingForArchive() async {
        let outcome = await run(
            url("https://app.example.com/dashboard"),
            html: page(
                "<div id=\"root\"></div><p>Loading your dashboard…</p>",
                head: "<title>Dashboard — Example</title>"),
            fetcher: MockArticleFetcher())

        XCTAssertEqual(outcome, .failed(.notReadable))
    }

    // MARK: - Bug 2: index pages read as articles

    func testPublisherFrontPageIsNotAnArticleEvenWhenItExtractsPastTheThreshold() async {
        let front = page(storyCards + readableProse)
        // Precondition: without the veto this page has enough body text to pass as
        // a readable article, which is exactly how it reached the tray.
        XCTAssertGreaterThanOrEqual(
            (try? ArticleExtraction().extract(
                html: front, baseURL: url("https://news.example.com/")).bodyTextLength) ?? 0,
            ArticleContent.readableBodyThreshold)

        let outcome = await run(
            url("https://news.example.com/"), html: front, fetcher: MockArticleFetcher())
        XCTAssertEqual(outcome, .failed(.notContent))
    }

    func testSearchResultsPageFailsBeforeAnyFetch() async {
        let fetcher = MockArticleFetcher()
        let outcome = await run(
            url("https://www.google.com/search?q=luna+reader"), html: nil, fetcher: fetcher)

        XCTAssertEqual(outcome, .failed(.notContent))
        XCTAssertTrue(fetcher.calls.isEmpty, "A search URL must fail without a round-trip")
    }

    /// A shop-host search URL is claimed by the deterministic `KnownSite`
    /// table as `.product`, which skips `ProductPageDetector.detect`. Without
    /// this guard, it would reach price extraction, find no price, and fall
    /// through to the article path.
    func testShopSearchURLFailsInsteadOfFallingThroughToTheArticlePath() async {
        let fetcher = MockArticleFetcher()
        let outcome = await run(
            url("https://www.amazon.com/s?k=headphones"), html: nil, fetcher: fetcher)

        XCTAssertEqual(outcome, .failed(.notContent))
        XCTAssertTrue(fetcher.calls.isEmpty)
    }

    // MARK: - Not too aggressive

    func testHardPaywallStubStillParksForTheArchiveReader() async {
        let outcome = await run(
            url("https://www.wsj.com/articles/a-real-story-11234"),
            html: page(
                "<p>Subscribe to continue reading.</p>",
                head: "<title>A Real Story - WSJ</title>"),
            fetcher: MockArticleFetcher())

        XCTAssertEqual(outcome, .needsArchive(title: "A Real Story - WSJ"))
    }

    /// A metered body cut back to headline links is genuinely link-dense. The
    /// listing veto has to stand down for it, or the unlock the Reader exists for
    /// would never run.
    func testLockedLinkDensePageIsNotVetoedAsAnIndex() async {
        let locked = page(
            storyCards + "<p>Subscribe to continue reading.</p>",
            head: """
            <title>A Metered Story</title>
            <script type="application/ld+json">{"isAccessibleForFree":false}</script>
            """)
        // The page really does look like an index on structure alone.
        XCTAssertTrue(ListingPage.isNonContentPage(
            url: url("https://metered.example.com/story"), html: locked))

        let outcome = await run(
            url("https://metered.example.com/story"), html: locked,
            fetcher: MockArticleFetcher())
        XCTAssertEqual(outcome, .needsArchive(title: "A Metered Story"))
    }

    func testReadableArticleIsUnaffected() async {
        let outcome = await run(
            url("https://blog.example.com/posts/thing"),
            html: page(readableProse, head: "<title>A Real Post</title>"),
            fetcher: MockArticleFetcher())

        guard case let .article(content, _) = outcome else {
            return XCTFail("Expected a readable article, got \(outcome)")
        }
        XCTAssertGreaterThanOrEqual(
            content.bodyTextLength, ArticleContent.readableBodyThreshold)
    }

    /// A page that never came back keeps every recovery route: the veto needs HTML
    /// to say anything, and a bot-blocked article still reaches the browser tier.
    func testBotBlockedArticleStillParksForBrowserRecovery() async {
        let target = url(
            "https://www.reuters.com/world/meta-used-ai-target-workers-2026-07-14/")
        let fetcher = MockArticleFetcher()
        fetcher.failingURLs = [target.absoluteString]

        let outcome = await IngestPipeline.process(
            IngestInput(url: target, source: .shareSheet),
            timeout: 5,
            fetcher: fetcher,
            articleProcessor: ArticleIngestProcessor(),
            productProcessor: ProductIngestProcessor())

        guard case .needsArchive = outcome else {
            return XCTFail("Expected a browser-recovery park, got \(outcome)")
        }
    }
}
