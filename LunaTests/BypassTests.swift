//
//  BypassTests.swift
//  LunaTests
//

import LunaArchiveReader
import LunaArticleIngest
import LunaFetch
import LunaHTMLClassification
import LunaModels
import LunaPaywallBypass
import LunaURLClassification
import WebKit
import XCTest
@testable import Luna

/// Paywall-bypass coverage: per-strategy URL/HTML transforms, the plan/selector that
/// orders them per host, the runner that executes them against a mocked fetcher, and
/// the direct-unlock readiness probe (run in a real `WKWebView`, since the JS is the
/// thing under test).
@MainActor
final class BypassTests: XCTestCase {

    // Shared fixture for the BypassRunner section below.
    private let articleURL = URL(string: "https://www.example.com/news/story")!
    private var fetcher: MockArticleFetcher!
    private var runner: BypassRunner!
    private lazy var js = SafariJSTestHarness(self)

    override func setUp() {
        super.setUp()
        fetcher = MockArticleFetcher()
        runner = BypassRunner(fetcher: fetcher)
    }

    // MARK: - AMPQueryBypass

    // The News Corp Australia unlock: a premium article redirects a plain read to the
    // publisher's own subscribe page, while the same URL with `?amp` returns the whole
    // body server-rendered. Both halves are covered here — the URL transform, the
    // strategy ordering it earns, and (against trimmed captures of the live pages) the
    // judgment that the subscribe pitch is not an article while the AMP document is.

    private func url(_ string: String) -> URL { URL(string: string)! }

    private let article = "https://www.theaustralian.com.au/wealth/retirement/"
        + "selffunded-retirees-hit-by-new-30pc-topup-tax-on-investments/news-story/"
        + "476176fcef46250d229a1612ce9f44d1"

    // MARK: The URL transform

    func testAppendsBareAMPFlagToAnArticleURL() {
        XCTAssertEqual(
            AMPQueryBypass.ampQueryURL(for: url(article))?.absoluteString,
            article + "?amp")
    }

    /// The flag is APPENDED, so an article that already carries query parameters
    /// (a tracking-tagged share) keeps them.
    func testExistingQueryIsPreserved() {
        XCTAssertEqual(
            AMPQueryBypass.ampQueryURL(for: url(article + "?utm_source=x"))?.absoluteString,
            article + "?utm_source=x&amp")
    }

    /// Never re-request the page we just requested: a URL that already asks for AMP
    /// yields no strategy URL at all.
    func testAlreadyAMPYieldsNil() {
        XCTAssertNil(AMPQueryBypass.ampQueryURL(for: url(article + "?amp")))
        XCTAssertNil(AMPQueryBypass.ampQueryURL(for: url(article + "?amp=1")))
        XCTAssertNil(AMPQueryBypass.ampQueryURL(for: url("https://www.heraldsun.com.au/story/amp")))
    }

    func testOnlyTheAMPQueryMastheadsQualify() {
        XCTAssertTrue(AMPQueryBypass.isAMPQueryHost(url(article)))
        XCTAssertTrue(AMPQueryBypass.isAMPQueryHost(url("https://theaustralian.com.au/x")))
        XCTAssertTrue(AMPQueryBypass.isAMPQueryHost(url("https://www.couriermail.com.au/x")))
        XCTAssertFalse(AMPQueryBypass.isAMPQueryHost(url("https://www.nytimes.com/x")))
        XCTAssertFalse(AMPQueryBypass.isAMPQueryHost(url("https://www.smh.com.au/x")))
        // Not a substring match on the registrable domain.
        XCTAssertFalse(AMPQueryBypass.isAMPQueryHost(url("https://nottheaustralian.com.au/x")))
        XCTAssertNil(AMPQueryBypass.ampQueryURL(for: url("https://www.nytimes.com/story")))
    }

    // MARK: Strategy ordering

    /// `?amp` is silent and one request, so it runs BEFORE the browser tier and the
    /// archive flow on these hosts — where nothing that needs the article's own HTML
    /// can work at all (the direct read never returns the article).
    func testAMPQueryLeadsThePlanForNewsCorpAU() {
        let locked = "<html><body>subscribe to continue reading</body></html>"
        XCTAssertEqual(
            BypassStrategySelector.strategies(for: url(article), directHTML: locked),
            [.ampQuery, .waybackRaw, .waybackPrePaywall, .directUnlock, .archiveToday])
        let plan = BypassPlan.make(for: url(article), directHTML: locked)
        XCTAssertEqual(plan.silent, [.ampQuery, .waybackRaw, .waybackPrePaywall])
        XCTAssertEqual(plan.webPreStages, [.directUnlock])
        XCTAssertTrue(plan.allowsArchiveToday)
    }

    /// A host with a rule but no AMP-by-query rendering keeps the plan it had: the silent
    /// archive pair, then the browser tier.
    func testOtherRuleHostsAreUnchanged() {
        let locked = "<html><body>subscribe to continue reading</body></html>"
        XCTAssertEqual(
            BypassStrategySelector.strategies(for: url("https://www.wsj.com/articles/x"),
                                              directHTML: locked),
            [.waybackRaw, .waybackPrePaywall, .directUnlock, .archiveToday])
    }

    // MARK: The live pages

    /// The AMP document ships the full body in `<section subscriptions-section=
    /// "content">` blocks that only `amp-subscriptions-*.js` hides — client-side,
    /// after load — so the bytes a URLSession gets ARE the article. It also declares
    /// `isAccessibleForFree:"False"`, which must not veto a body this long.
    func testAMPCaptureExtractsAsAReadableArticle() throws {
        let html = AMPQueryBypass.extractableHTML(
            from: BypassFixtures.html("Readable/theaustralian-amp.html"))
        let content = try ArticleExtraction().extract(html: html, baseURL: url(article + "?amp"))
        XCTAssertGreaterThan(content.bodyTextLength, 2500)
        XCTAssertTrue(ArticleExtraction.isReadableArticle(content, html: html))
        XCTAssertTrue(content.wholeText.contains("top-up tax"))
    }

    /// …but ONLY once the gate is stripped. AMP puts the pitch in the same document as
    /// the story (`content-not-granted`), and its "Already a subscriber? Log in" copy
    /// is a `PaywallDetector` gate marker — which fires at ANY body length. So the
    /// unhide is load-bearing, not cosmetic.
    func testAMPGateStripRemovesThePitchAndKeepsTheBody() {
        let raw = BypassFixtures.html("Readable/theaustralian-amp.html")
        XCTAssertTrue(raw.contains("content-not-granted"))
        XCTAssertTrue(raw.lowercased().contains("already a subscriber?"))

        let stripped = AMPQueryBypass.extractableHTML(from: raw)
        XCTAssertFalse(stripped.contains("content-not-granted"))
        XCTAssertFalse(stripped.lowercased().contains("already a subscriber?"))
        XCTAssertFalse(stripped.contains("Get the full story"))
        // The body sections survive — with the attribute that hid them removed.
        XCTAssertFalse(stripped.contains("subscriptions-section=\"content\""))
        XCTAssertTrue(stripped.contains("Under previous arrangements"))
    }

    /// The transform is a no-op on markup that carries no AMP subscription furniture.
    func testAMPGateStripLeavesOrdinaryHTMLAlone() {
        let html = "<html><body><p>Ordinary page.</p></body></html>"
        XCTAssertEqual(AMPQueryBypass.extractableHTML(from: html), html)
    }

    /// AMP has no plain images, and the extractor only knows `img` — so an unrewritten
    /// AMP document arrives as text with every photo and chart dropped.
    func testAMPImagesBecomeExtractableImages() throws {
        let html = AMPQueryBypass.extractableHTML(
            from: BypassFixtures.html("Readable/theaustralian-amp.html"))
        XCTAssertFalse(html.contains("<amp-img"))
        let content = try ArticleExtraction().extract(html: html, baseURL: url(article + "?amp"))
        let images = content.blocks.filter { $0.kind == .image }
        XCTAssertFalse(images.isEmpty, "the AMP body's images must survive the rewrite")
        XCTAssertTrue(
            images.contains { ($0.imageURLString ?? "").contains("content.api.news") },
            "expected the publisher's own image URLs, got \(images.map { $0.imageURLString ?? "-" })")
    }

    /// And the reason the redirect must be caught at the fetch layer: the subscribe
    /// page's own copy is long enough, and free enough of gate wording, that the
    /// content-based detector cannot be relied on to reject it. This test documents
    /// that (whatever the detector says today), which is why
    /// `ArticleFetcher.subscribeRedirectLanding` exists.
    func testSubscribeInterstitialIsRecognizedByItsURLNotItsProse() throws {
        let html = BypassFixtures.html("Readable/theaustralian-subscribe.html")
        let interstitial = url(
            "https://www.theaustralian.com.au/subscribe/news/1/?sourceCode=TAWEB_MRE170_a"
            + "&dest=" + article + "&memtype=anonymous&mode=premium")
        // It parses into something article-shaped — the pitch, not the story.
        let content = try ArticleExtraction().extract(html: html, baseURL: interstitial)
        XCTAssertFalse(content.wholeText.contains("top-up tax’, upending"))
        // The URL is what proves it: a request for the ARTICLE that lands here failed.
        XCTAssertEqual(
            ArticleFetcher.subscribeRedirectLanding(requested: url(article), finalURL: interstitial),
            interstitial)
        XCTAssertTrue(NewsAggregatorUnwrapper.isInterstitialURL(interstitial))
    }

    // MARK: - ArchiveDirectBypassReadiness

    // The direct-unlock pre-stage's readiness probe, run against fixture pages in a
    // real `WKWebView` (the JS is the thing under test, so evaluating it is the only
    // honest way to test it).
    //
    // The case that motivated these: WSJ wraps TEASER CARDS in their own `<article>`,
    // so a page whose real body hasn't hydrated still has article elements in it.
    // Treating their mere existence as "the article rendered" let the whole-document
    // extraction save teaser prose + page furniture as the article.

    /// The readiness probe's verdict for `html`, evaluated in the ONE web view
    /// the whole bundle shares (`SafariJSTestHarness`). A per-test `WKWebView`
    /// spends a WebContent process launch on every case; navigating the shared
    /// view to a new document gives the same fresh JS context for free.
    private func probeResult(for html: String) -> String {
        js.load(html: html, urlString: "https://example.com/a", scripts: [])
        return js.string(ArchiveWebReaderViewController.directBypassStageProbeJavaScript) ?? ""
    }

    private func prose(_ characters: Int) -> String {
        String(repeating: "The eclipse crossed the meridian at dawn. ",
               count: characters / 42 + 1)
    }

    /// A page carrying only teaser cards is NOT ready, however many of them there
    /// are — this is the WSJ shape that used to read as a rendered article.
    func testTeaserArticleCardsAreNotReadiness() {
        let cards = (0..<6).map { index in
            "<article><h3>Teaser \(index)</h3><p>A one-line standfirst.</p></article>"
        }.joined()
        let result = probeResult(for: "<html><body><h1>Section</h1>\(cards)</body></html>")

        XCTAssertNotEqual(
            result, "content-root",
            "Teaser cards in their own <article> must not read as a rendered article")
    }

    /// The real body, wherever it sits among the teasers, IS readiness — the probe
    /// scans every match rather than stopping at the first.
    func testRealArticleAmongTeasersIsReadiness() {
        let teaser = "<article><h3>Teaser</h3><p>A one-line standfirst.</p></article>"
        let real = "<article><h1>The real one</h1><p>\(prose(2000))</p></article>"
        let result = probeResult(
            for: "<html><body>\(teaser)\(real)\(teaser)</body></html>")

        XCTAssertEqual(result, "content-root")
    }

    /// A container holding an article's worth of text still reads as ready on its
    /// own — the ordinary case must not regress.
    func testSingleRenderedArticleIsReadiness() {
        let result = probeResult(for: """
        <html><body><article><h1>Story</h1><p>\(prose(1600))</p></article></body></html>
        """)

        XCTAssertEqual(result, "content-root")
    }

    /// The bar is the extractor's own threshold, so the probe can never call a page
    /// ready that extraction would then reject as unreadable.
    func testReadinessBarMatchesTheExtractorsReadableThreshold() {
        let under = probeResult(for: """
        <html><body><article><p>\(prose(ArticleContent.readableBodyThreshold - 400))</p></article></body></html>
        """)
        let over = probeResult(for: """
        <html><body><article><p>\(prose(ArticleContent.readableBodyThreshold + 400))</p></article></body></html>
        """)

        XCTAssertNotEqual(under, "content-root")
        XCTAssertEqual(over, "content-root")
    }

    /// An access CAPTCHA with no article behind it still reveals for the user.
    func testAccessChallengeIsStillDetectedWhenNoArticleRendered() {
        let result = probeResult(for: """
        <html><body><iframe src="https://www.google.com/recaptcha/api2/anchor"></iframe></body></html>
        """)

        XCTAssertEqual(result, "challenge")
    }

    // MARK: - ArchiveWebPreStage

    func testRuleListedPaywalledArticlesUseDirectUnlockFirst() {
        let url = URL(string: "https://www.wsj.com/articles/x")!
        XCTAssertEqual(
            ArchiveWebReaderViewController.webPreStageURLs(for: url),
            [url])
    }

    // MARK: - BypassPlan

    func testWSJUsesDirectUnlockThenArchive() {
        let url = URL(string: "https://www.wsj.com/articles/x")!
        let plan = BypassPlan.make(for: url, directHTML: "<html>subscribe to continue</html>")
        XCTAssertEqual(plan.silent, [.waybackRaw, .waybackPrePaywall])
        XCTAssertEqual(plan.webPreStages, [.directUnlock])
        XCTAssertTrue(plan.allowsArchiveToday)
    }

    func testNonPaywalledHostHasNoArchivePlan() {
        let url = URL(string: "https://example.com/story")!
        let html = "<article>" + String(repeating: "Free article. ", count: 100) + "</article>"
        let plan = BypassPlan.make(for: url, directHTML: html)
        XCTAssertTrue(plan.silent.isEmpty)
        XCTAssertTrue(plan.webPreStages.isEmpty)
        XCTAssertFalse(plan.allowsArchiveToday)
    }

    func testNYTUsesItsDirectUnlockRuleBeforeArchive() {
        let url = URL(string: "https://www.nytimes.com/2026/06/26/world/americas/x.html")!
        let plan = BypassPlan.make(for: url, directHTML: "<html>subscribe to continue reading</html>")
        XCTAssertEqual(plan.silent, [.waybackRaw, .waybackPrePaywall])
        XCTAssertFalse(plan.silent.contains(.trailingDotHost))
        XCTAssertEqual(plan.webPreStages, [.directUnlock])
        XCTAssertTrue(plan.allowsArchiveToday)
    }

    /// Distinct from `url(_:)` above: this variant traps with a descriptive message
    /// on a malformed literal instead of a bare force-unwrap. Used by the
    /// `TrailingDotBypass` tests below.
    private func urlOrFail(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    // MARK: - BypassRunner

    // Exercises `BypassRunner` against a mock `HTMLFetching`: asserts each strategy
    // calls the right fetch with the right UA / referer / XFF / URL, and that the
    // WKWebView-only strategies return nil (not silent).
    // (Shared `articleURL`/`fetcher`/`runner` fixtures and their `setUp` are declared
    // at the top of this class.)

    /// A long readable body so extraction clears the readability gate.
    private func readableHTML(_ marker: String = "body") -> String {
        let paragraph = "<p>" + String(repeating: "An ordinary readable sentence about the topic. ", count: 30) + "</p>"
        return "<html><head><title>Real Story \(marker)</title></head><body><article>\(paragraph)\(paragraph)</article></body></html>"
    }

    func testUserAgentStrategySendsCrawlerUAAndXFF() async {
        fetcher.htmlByURL[articleURL.absoluteString] = readableHTML()
        let result = await runner.run(.userAgent(.googlebotDesktop), url: articleURL, directHTML: nil)
        XCTAssertNotNil(result)
        let call = fetcher.calls.first
        XCTAssertEqual(call?.kind, .userAgent)
        XCTAssertEqual(call?.userAgent, CrawlerAgent.googlebotDesktop.userAgent)
        XCTAssertEqual(call?.xForwardedFor, "66.249.66.1")
    }

    func testBingbotStrategyOmitsXFF() async {
        fetcher.htmlByURL[articleURL.absoluteString] = readableHTML()
        _ = await runner.run(.userAgent(.bingbot), url: articleURL, directHTML: nil)
        XCTAssertEqual(fetcher.calls.first?.userAgent, CrawlerAgent.bingbot.userAgent)
        XCTAssertNil(fetcher.calls.first?.xForwardedFor)
    }

    func testRefererStrategySendsReferer() async {
        fetcher.htmlByURL[articleURL.absoluteString] = readableHTML()
        _ = await runner.run(.referer(.twitter), url: articleURL, directHTML: nil)
        XCTAssertEqual(fetcher.calls.first?.kind, .referer)
        XCTAssertEqual(fetcher.calls.first?.referer, "https://t.co/")
    }

    func testTrailingDotFetchesDottedHostButKeepsCanonicalBase() async {
        let dotted = URL(string: "https://www.example.com./news/story")!
        fetcher.htmlByURL[dotted.absoluteString] = readableHTML()
        let result = await runner.run(.trailingDotHost, url: articleURL, directHTML: nil)
        XCTAssertNotNil(result)
        XCTAssertEqual(fetcher.calls.first?.url, dotted)
    }

    func testFreshSessionUsesNoCookies() async {
        fetcher.htmlByURL[articleURL.absoluteString] = readableHTML()
        _ = await runner.run(.freshSession, url: articleURL, directHTML: nil)
        XCTAssertEqual(fetcher.calls.first?.kind, .freshSession)
        XCTAssertEqual(fetcher.calls.first?.noCookies, true)
    }

    func testWaybackRawStrategy() async {
        fetcher.htmlByURL[articleURL.absoluteString] = readableHTML()
        _ = await runner.run(.waybackRaw, url: articleURL, directHTML: nil)
        XCTAssertEqual(fetcher.calls.first?.kind, .waybackRaw)
    }

    func testWaybackPrePaywallStrategy() async {
        fetcher.prePaywallHTMLByURL[articleURL.absoluteString] = readableHTML()
        let result = await runner.run(.waybackPrePaywall, url: articleURL, directHTML: nil)
        XCTAssertNotNil(result)
        XCTAssertEqual(fetcher.calls.first?.kind, .waybackPrePaywall)
    }

    func testJinaReaderStrategy() async {
        fetcher.htmlByURL[articleURL.absoluteString] = readableHTML()
        _ = await runner.run(.jinaReader, url: articleURL, directHTML: nil)
        XCTAssertEqual(fetcher.calls.first?.kind, .jina)
    }

    func testLadderProxyFetchesProxyURL() async {
        let proxyURL = LadderProxy.oneFt.url(for: articleURL)!
        fetcher.htmlByURL[proxyURL.absoluteString] = readableHTML()
        let result = await runner.run(.ladderProxy(.oneFt), url: articleURL, directHTML: nil)
        XCTAssertNotNil(result)
        XCTAssertEqual(fetcher.calls.first?.url, proxyURL)
        XCTAssertEqual(fetcher.calls.first?.kind, .plain)
    }

    func testAMPFollowsDiscoveredURL() async {
        let ampURL = URL(string: "https://www.example.com/news/story/amp")!
        let directHTML = "<html><head><link rel=\"amphtml\" href=\"\(ampURL.absoluteString)\"></head><body></body></html>"
        fetcher.htmlByURL[ampURL.absoluteString] = readableHTML("amp")
        let result = await runner.run(.amp, url: articleURL, directHTML: directHTML)
        XCTAssertNotNil(result)
        XCTAssertEqual(fetcher.calls.first?.url, ampURL)
    }

    func testAMPWithoutLinkReturnsNilAndDoesNotFetch() async {
        let result = await runner.run(.amp, url: articleURL, directHTML: "<html><body></body></html>")
        XCTAssertNil(result)
        XCTAssertTrue(fetcher.calls.isEmpty)
    }

    func testJSONLDBodyIsZeroNetwork() async {
        let html = BypassFixtures.html("jsonld-bloomberg.html")
        let result = await runner.run(.jsonLDBody, url: articleURL, directHTML: html)
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.content.bodyTextLength > 600)
        XCTAssertTrue(fetcher.calls.isEmpty, "JSON-LD recovery must not hit the network")
    }

    func testArchiveTodayIsNotSilent() async {
        let archive = await runner.run(.archiveToday, url: articleURL, directHTML: nil)
        XCTAssertNil(archive)
        XCTAssertTrue(fetcher.calls.isEmpty)
    }

    func testFetchFailureFallsThroughToNil() async {
        fetcher.failingURLs.insert(articleURL.absoluteString)
        let result = await runner.run(.waybackRaw, url: articleURL, directHTML: nil)
        XCTAssertNil(result)
    }

    // MARK: - BypassStrategySelector

    private let locked = "<html><body>subscribe to continue reading</body></html>"

    func testNotPaywalledReturnsEmpty() {
        let html = "<html><body><article>" + String(repeating: "Free article. ", count: 100)
            + "</article></body></html>"
        XCTAssertEqual(BypassStrategySelector.strategies(
            for: url("https://example.com/x"), directHTML: html), [])
    }

    func testRuleHostTriesTheArchivesSilentlyThenDirectUnlock() {
        for article in ["https://www.wsj.com/articles/x", "https://www.nytimes.com/story"] {
            XCTAssertEqual(
                BypassStrategySelector.strategies(for: url(article), directHTML: locked),
                [.waybackRaw, .waybackPrePaywall, .directUnlock, .archiveToday], article)
        }
    }

    func testUnknownHostUsesArchive() {
        // Wayback (both ends of the capture history) is silent and CAPTCHA-free, so it
        // precedes the user-visible archive.today flow.
        XCTAssertEqual(
            BypassStrategySelector.strategies(
                for: url("https://unknown.example/story"), directHTML: locked),
            [.waybackRaw, .waybackPrePaywall, .archiveToday])
    }

    func testTruncatedGenerousPreviewGetsTheArchivePlan() {
        // The Paris Review shape: a long readable preview cut off server-side, with the
        // subscribe gate standing where the rest of the interview should be. No metadata
        // lock and no thin body, so ONLY the structural signal opens the plan.
        let paragraph = "<p>Interview prose paragraph running long enough to count as real "
            + "reported text rather than a caption or a byline line.</p>"
        let truncated = """
        <html><body><div class="article-body-wrap">
          <main class="article-body">\(String(repeating: paragraph, count: 20))</main>
          <div class="paywall"><h1>Want to keep reading?</h1>
            <h4>Already a subscriber? Sign in below.</h4></div>
        </div></body></html>
        """
        XCTAssertEqual(
            BypassStrategySelector.strategies(
                for: url("https://www.theparisreview.org/interviews/3810/x"),
                directHTML: truncated),
            [.waybackRaw, .waybackPrePaywall, .archiveToday])
    }

    func testRuleHostWithoutMarkersStillBypasses() {
        // delish.com is in the unlock rule table but NOT our hard-paywall list, so a
        // no-marker page yields a `.notPaywalled` gate decision — the exact case the
        // toggle-on override flips.
        let noEvidence = "<html><body><p>" + String(repeating: "short. ", count: 5) + "</p></body></html>"
        let known = url("https://www.delish.com/story")
        XCTAssertEqual(
            BypassStrategySelector.strategies(for: known, directHTML: noEvidence),
            [.waybackRaw, .waybackPrePaywall, .directUnlock, .archiveToday])
    }

    func testUnknownHostWithoutMarkersIsNotBypassed() {
        let noEvidence = "<html><body><p>" + String(repeating: "short. ", count: 5) + "</p></body></html>"
        XCTAssertEqual(
            BypassStrategySelector.strategies(
                for: url("https://randomblog.example/post"), directHTML: noEvidence),
            [])
    }

    // MARK: - Bot-refused front doors (browser recovery without a site rule)

    /// A free article behind a bot-mitigation front door: Vercel answers 429 with a
    /// "Security Checkpoint" to every silent strategy, so the direct read yields no HTML
    /// at all. That refusal is about the CLIENT, not the page, and a real browser gets a
    /// 200 with the whole article — so the browser leg must be scheduled even though
    /// piratewires.com has no unlock rule (it is on the upstream `noFix` list).
    func testClientRefusedRulelessHostEarnsTheBrowserLeg() {
        let article = url("https://www.piratewires.com/p/inside-the-coke-fueled-rise-and-fall")
        for refusal: SaveFailureReason in [.httpStatus(429), .httpStatus(403), .httpStatus(401)] {
            XCTAssertEqual(
                BypassStrategySelector.strategies(
                    for: article, directHTML: nil, directFailure: refusal),
                [.waybackRaw, .waybackPrePaywall, .directUnlock, .archiveToday],
                "\(refusal)")
        }
    }

    /// The refusal gate must stay narrow, or every unreachable page would park itself as
    /// "needs archive" instead of failing honestly. A page that is GONE, a server fault
    /// and a transport failure all keep the plain archive plan — no browser leg.
    func testNonRefusalFailuresDoNotEarnTheBrowserLeg() {
        let article = url("https://www.piratewires.com/p/story")
        let notRefusals: [SaveFailureReason?] = [
            .httpStatus(404), .httpStatus(410), .httpStatus(503), .httpStatus(500),
            .offline, .timedOut, .network("DNS failed"), .notReadable, nil,
        ]
        for reason in notRefusals {
            XCTAssertEqual(
                BypassStrategySelector.strategies(
                    for: article, directHTML: nil, directFailure: reason),
                [.waybackRaw, .waybackPrePaywall, .archiveToday],
                "\(String(describing: reason))")
        }
    }

    /// `browserMayRecover` is the whole policy, so pin it directly.
    func testBrowserMayRecoverOnlyForClientRefusalCodes() {
        for code in [401, 403, 429] {
            XCTAssertTrue(SaveFailureReason.httpStatus(code).browserMayRecover, "\(code)")
        }
        for code in [200, 404, 410, 500, 502, 503] {
            XCTAssertFalse(SaveFailureReason.httpStatus(code).browserMayRecover, "\(code)")
        }
        for reason: SaveFailureReason in [.offline, .timedOut, .notReadable, .notContent,
                                          .notHTML, .tooLarge, .subscribeRedirect, .unknown] {
            XCTAssertFalse(reason.browserMayRecover, "\(reason)")
        }
    }

    /// The archive reader IS the browser tier and only opens for a page nothing silent
    /// could read, so it tries the live page once before the archive CAPTCHA — for any
    /// ruleless host, not just a refused one. This is a different question from whether
    /// the page earned parking, which is why it is a separate flag.
    func testBrowserTierTriesTheLivePageBeforeTheArchive() {
        XCTAssertEqual(
            BypassStrategySelector.strategies(
                for: url("https://unknown.example/story"), directHTML: locked,
                silentTierExhausted: true),
            [.waybackRaw, .waybackPrePaywall, .directUnlock, .archiveToday])
    }

    /// …but not for a hard-paywall host (the wall is certain, so a live load would only
    /// delay the archive flow) nor for a URL that is already a snapshot.
    func testBrowserTierSkipsTheLivePageWhereItCannotHelp() {
        // theinformation.com is a hard-paywall host with NO unlock rule — so this asserts
        // the hard-paywall skip itself, not a rule path that would emit the leg anyway.
        XCTAssertFalse(
            BypassStrategySelector.strategies(
                for: url("https://www.theinformation.com/articles/abc"), directHTML: locked,
                silentTierExhausted: true)
                .contains(.directUnlock))
        XCTAssertFalse(
            BypassStrategySelector.strategies(
                for: url("https://archive.is/newest/https://example.com/x"),
                directHTML: locked, silentTierExhausted: true)
                .contains(.directUnlock))
    }

    // MARK: - TrailingDotBypass

    // Covers the pure trailing-dot URL transform. Generalized from the former
    // NYT-only bypass: the transform now applies to ANY host (the selector decides
    // when to use it), so these assert the transform itself plus the retained NYT
    // host classification.
    // (Uses `urlOrFail(_:)`, declared above — both originals declared the identical
    // fatalError-guarded helper under the name `url`.)

    func testAddsTrailingDotToHostPreservingPathAndQuery() {
        XCTAssertEqual(
            TrailingDotBypass.trailingDotURL(for: urlOrFail("https://www.nytimes.com/2026/06/20/world/story.html?smid=x"))?
                .absoluteString,
            "https://www.nytimes.com./2026/06/20/world/story.html?smid=x")
    }

    func testApexHost() {
        XCTAssertEqual(
            TrailingDotBypass.trailingDotURL(for: urlOrFail("https://nytimes.com/article"))?.absoluteString,
            "https://nytimes.com./article")
    }

    func testSubdomainHost() {
        XCTAssertEqual(
            TrailingDotBypass.trailingDotURL(for: urlOrFail("https://cooking.nytimes.com/recipes/123"))?.absoluteString,
            "https://cooking.nytimes.com./recipes/123")
    }

    /// Now generalized: a non-NYT host IS transformed (the host guard was dropped).
    func testNonNYTHostIsTransformed() {
        XCTAssertEqual(
            TrailingDotBypass.trailingDotURL(for: urlOrFail("https://www.wsj.com/articles/x"))?.absoluteString,
            "https://www.wsj.com./articles/x")
        XCTAssertEqual(
            TrailingDotBypass.trailingDotURL(for: urlOrFail("https://www.bloomberg.com/news/y"))?.host,
            "www.bloomberg.com.")
    }

    func testAlreadyDottedReturnsNil() {
        XCTAssertNil(TrailingDotBypass.trailingDotURL(for: urlOrFail("https://www.nytimes.com./article")))
        XCTAssertNil(TrailingDotBypass.trailingDotURL(for: urlOrFail("https://www.wsj.com./articles/x")))
    }

    func testHostClassification() {
        XCTAssertTrue(TrailingDotBypass.isNYTHost("www.nytimes.com"))
        XCTAssertTrue(TrailingDotBypass.isNYTHost("nytimes.com"))
        XCTAssertTrue(TrailingDotBypass.isNYTHost("cooking.nytimes.com"))
        XCTAssertTrue(TrailingDotBypass.isNYTHost("nytimes.com."))
        XCTAssertFalse(TrailingDotBypass.isNYTHost("wsj.com"))
        XCTAssertFalse(TrailingDotBypass.isNYTHost("notnytimes.com.attacker.com"))
    }
}
