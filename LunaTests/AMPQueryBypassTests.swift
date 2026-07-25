//
//  AMPQueryBypassTests.swift
//  LunaTests
//

import LunaFetch
import LunaHTMLClassification
import LunaPaywallBypass
import LunaURLClassification
import XCTest
@testable import Luna

/// The News Corp Australia unlock: a premium article redirects a plain read to the
/// publisher's own subscribe page, while the same URL with `?amp` returns the whole
/// body server-rendered. Both halves are covered here — the URL transform, the
/// strategy ordering it earns, and (against trimmed captures of the live pages) the
/// judgment that the subscribe pitch is not an article while the AMP document is.
final class AMPQueryBypassTests: XCTestCase {

    private func url(_ string: String) -> URL { URL(string: string)! }

    private let article = "https://www.theaustralian.com.au/wealth/retirement/"
        + "selffunded-retirees-hit-by-new-30pc-topup-tax-on-investments/news-story/"
        + "476176fcef46250d229a1612ce9f44d1"

    // MARK: - The URL transform

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

    // MARK: - Strategy ordering

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

    // MARK: - The live pages

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
}
