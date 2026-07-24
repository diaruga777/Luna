//
//  ArticleResolverTests.swift
//  LunaTests
//

import LunaArticleIngest
import LunaPaywallBypass
import LunaHTMLClassification
import LunaModels
import XCTest
@testable import Luna

final class ArticleResolverTests: XCTestCase {

    /// A paragraph block of `length` characters.
    private func content(title: String, bodyLength: Int) -> ArticleContent {
        let body = String(repeating: "a", count: bodyLength)
        return ArticleContent(title: title, blocks: [.init(kind: .paragraph, text: body, links: [])])
    }

    /// An `ExtractedArticle` of `bodyLength` characters with `title`.
    private func extracted(title: String, bodyLength: Int, html: String) -> ExtractedArticle {
        ExtractedArticle(content: content(title: title, bodyLength: bodyLength), sourceHTML: html)
    }

    func testDirectReadableWinsAndSkipsArchive() {
        let direct = content(title: "Real", bodyLength: 2000)
        let result = ArticleResolver.resolution(
            direct: ExtractedArticle(content: direct, sourceHTML: "<html>direct</html>"), archived: nil)
        XCTAssertEqual(result, .readable(direct, html: "<html>direct</html>"))
    }

    func testArchiveReadableUsedWhenDirectIsStub() {
        let directStub = extracted(title: "Paywalled", bodyLength: 50, html: "<stub>")
        let archived = content(title: "Paywalled", bodyLength: 2000)
        let result = ArticleResolver.resolution(
            direct: directStub, archived: ExtractedArticle(content: archived, sourceHTML: "<archive>"))
        XCTAssertEqual(result, .readable(archived, html: "<archive>"))
    }

    /// FT-shaped: the direct fetch returns a titled subscription stub and the
    /// archive fetch fails entirely — the title must survive as `.paywalled`.
    func testDirectStubTitleSurvivesWhenArchiveFails() {
        let directStub = extracted(title: "FT Headline", bodyLength: 80, html: "<stub>")
        let result = ArticleResolver.resolution(direct: directStub, archived: nil)
        XCTAssertEqual(result, .paywalled(title: "FT Headline"))
    }

    /// WSJ-shaped: the direct fetch 401s (no content at all) but the archive
    /// snapshot, while itself paywalled, still carries the real title.
    func testArchiveTitleUsedWhenDirectFails() {
        let archivedStub = extracted(title: "WSJ Headline", bodyLength: 120, html: "<archive>")
        let result = ArticleResolver.resolution(direct: nil, archived: archivedStub)
        XCTAssertEqual(result, .paywalled(title: "WSJ Headline"))
    }

    func testDirectTitlePreferredOverArchiveTitle() {
        let directStub = extracted(title: "Canonical", bodyLength: 40, html: "<stub>")
        let archivedStub = extracted(title: "Archive Copy", bodyLength: 60, html: "<archive>")
        let result = ArticleResolver.resolution(direct: directStub, archived: archivedStub)
        XCTAssertEqual(result, .paywalled(title: "Canonical"))
    }

    func testPlaceholderTitleIsNotTreatedAsReal() {
        let directStub = extracted(title: "Untitled", bodyLength: 40, html: "<stub>")
        let result = ArticleResolver.resolution(direct: directStub, archived: nil)
        // The page WAS reached — it just held nothing usable — so the reason is a
        // content failure, never whatever the transport reported.
        XCTAssertEqual(result, .unreadable(.notReadable))
    }

    /// A page that never came back carries the fetch's own reason forward, so the
    /// failed card can say "403" instead of "couldn't fetch".
    func testUnreachablePageCarriesTheFetchReason() {
        let result = ArticleResolver.resolution(
            direct: nil, archived: nil, directFailure: .httpStatus(403))
        XCTAssertEqual(result, .unreadable(.httpStatus(403)))
    }

    /// A reached-but-empty page must NOT inherit the direct fetch's reason: the
    /// direct read here succeeded, and any captured error belongs to an earlier
    /// attempt.
    func testReachedPageIgnoresAStaleFetchReason() {
        let directStub = extracted(title: "", bodyLength: 10, html: "<stub>")
        let result = ArticleResolver.resolution(
            direct: directStub, archived: nil, directFailure: .offline)
        XCTAssertEqual(result, .unreadable(.notReadable))
    }

    func testNothingReachableIsUnreadable() {
        let result = ArticleResolver.resolution(direct: nil, archived: nil)
        XCTAssertEqual(result, .unreadable(nil))
    }

    // MARK: - silent-strategy loop: advance-on-failure (GOAL 2 routing reliability)

    /// A long readable article body so extraction clears the readability gate.
    private func readableHTML(_ marker: String) -> String {
        let paragraph = "<p>" + String(repeating: "An ordinary readable sentence about \(marker). ", count: 30) + "</p>"
        return "<html><head><title>Real \(marker)</title></head><body><article>\(paragraph)\(paragraph)</article></body></html>"
    }

    /// A locked teaser (short body + schema.org lock) that must be REJECTED.
    private let lockedHTML = "<html><head><title>NYT Headline</title></head><body><p>Lede only.</p>"
        + #"<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>"#
        + "</body></html>"

    /// A site unlock rule (WSJ → Referer:Drudge): the resolver runs the
    /// rule's silent request technique. Here the Drudge-referer fetch returns the full
    /// article, so it wins before any browser-tier / archive fallback.
    func testResolverSilentRefererUnlockWinsForWSJ() async {
        let articleURL = URL(string: "https://www.wsj.com/articles/x_199845b1.html")!
        let fetcher = MockArticleFetcher()
        fetcher.htmlByURL[articleURL.absoluteString] = lockedHTML             // direct read = locked
        fetcher.refererHTMLByURL[articleURL.absoluteString] = readableHTML("drudge")  // referer read = full

        let result = await ArticleResolver.resolve(url: articleURL, fetcher: fetcher)
        if case .readable = result {} else { return XCTFail("expected readable, got \(result)") }
        // The silent leg used a Drudge-referer fetch (WSJ's rule), not a crawler UA.
        let refererCall = fetcher.calls.first { $0.kind == .referer }
        XCTAssertEqual(refererCall?.referer, "https://www.drudgereport.com/")
    }

    /// For WSJ, the silent Referer fetch stays locked and there's no
    /// JSON-LD body: the resolver parks it under its title for the browser-tier /
    /// archive flow rather than returning a locked page.
    func testResolverParksWhenSilentRefererStaysLocked() async {
        let articleURL = URL(string: "https://www.wsj.com/articles/x_199845b1.html")!
        let fetcher = MockArticleFetcher()
        // Both the direct AND the Drudge-referer fetch return the same locked teaser.
        fetcher.htmlByURL[articleURL.absoluteString] = lockedHTML

        let result = await ArticleResolver.resolve(url: articleURL, fetcher: fetcher)
        XCTAssertEqual(result, .paywalled(title: "NYT Headline"))   // lockedHTML's title
        XCTAssertTrue(fetcher.calls.contains { $0.kind == .referer })
    }

    /// A full, readable article body that ALSO still carries the publisher's
    /// schema.org lock — the shape of New Statesman subscriber pages and the Safari
    /// "Read in Luna" hand-off, where the body is present but the stale
    /// `isAccessibleForFree:false` remains in the page's JSON-LD.
    private func readableButLockedHTML(_ marker: String) -> String {
        let paragraph = "<p>" + String(repeating: "An ordinary readable sentence about \(marker). ", count: 30) + "</p>"
        return "<html><head><title>Real \(marker)</title>"
            + #"<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>"#
            + "</head><body><article>\(paragraph)\(paragraph)</article></body></html>"
    }

    /// New Statesman-shaped direct HTML can contain the full story while still declaring
    /// a schema.org lock. Long, gate-free article prose should resolve directly instead
    /// of parking for archive.today.
    func testLongDirectArticleBeatsStaleSchemaLock() async {
        let articleURL = URL(string: "https://www.newstatesman.com/world/asia/2026/07/in-hong-kong-i-saw-the-coming-chinese-century")!
        let html = readableButLockedHTML("newstatesman")
        let fetcher = MockArticleFetcher()
        fetcher.htmlByURL[articleURL.absoluteString] = html

        let result = await ArticleResolver.resolve(
            url: articleURL, fetcher: fetcher, trustsPrefetchedHTML: false)
        if case .readable = result {} else { XCTFail("long direct body should be readable, got \(result)") }
        XCTAssertEqual(fetcher.calls.first?.kind, .plain)
    }

    /// The Safari hand-off still accepts shorter already-unlocked article DOMs on body
    /// length alone, because the page the user captured is trusted.
    func testTrustedSafariPrefetchBypassesShortStaleSchemaLock() async {
        let articleURL = URL(string: "https://www.wsj.com/articles/unlocked_199845b1.html")!
        let paragraph = "<p>" + String(repeating: "Short unlocked article sentence. ", count: 25) + "</p>"
        let html = "<html><head><title>Real wsj</title>"
            + #"<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>"#
            + "</head><body><article>\(paragraph)\(paragraph)</article></body></html>"

        let parked = await ArticleResolver.resolve(
            url: articleURL, prefetchedHTML: html, fetcher: MockArticleFetcher(),
            trustsPrefetchedHTML: false)
        if case .readable = parked { XCTFail("short untrusted prefetch must not bypass the schema lock") }

        let result = await ArticleResolver.resolve(
            url: articleURL, prefetchedHTML: html, fetcher: MockArticleFetcher(),
            trustsPrefetchedHTML: true)
        if case .readable = result {} else { XCTFail("trusted prefetch should be readable, got \(result)") }
    }

    // MARK: - trusted Safari capture is a floor, not a winner

    /// Readable prose of `paragraphs` × 30 sentences, with no lock declaration.
    private func proseHTML(_ marker: String, paragraphs: Int) -> String {
        let paragraph = "<p>" + String(repeating: "An ordinary readable sentence about \(marker). ", count: 30) + "</p>"
        return "<html><head><title>Real \(marker)</title></head><body><article>"
            + String(repeating: paragraph, count: paragraphs) + "</article></body></html>"
    }

    /// The NYT-shaped Safari capture: the publisher's TRUNCATED render. Over the
    /// readable threshold (1200) so a trusted hand-off accepts it on length, but under
    /// `PaywallDetector.shortBodyThreshold` (2500) so its schema.org lock still counts —
    /// the live article measures ~2.2k rendered characters of a ~4.6k body.
    private func truncatedLockedCaptureHTML() -> String {
        let paragraph = "<p>" + String(repeating: "An ordinary sentence from the enzyme study. ", count: 24) + "</p>"
        return "<html><head><title>NYT Enzyme Story</title>"
            + #"<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>"#
            + "</head><body><article>\(paragraph)\(paragraph)</article></body></html>"
    }

    private func bodyLength(of resolution: ArticleResolution) -> Int? {
        if case let .readable(content, _) = resolution { return content.bodyTextLength }
        return nil
    }

    /// NYT-shaped: Safari can apply the site rule's script-block half but cannot spoof
    /// the request UA, so the captured DOM is the publisher's TRUNCATED render and still
    /// declares a lock. The resolver must spend the one silent custom-UA fetch the rule
    /// describes and return that fuller body instead of the capture.
    func testTrustedCaptureStillLockedIsUpgradedBySilentSiteUnlock() async {
        let articleURL = URL(string: "https://www.nytimes.com/2026/07/24/science/enzymes.html")!
        let capture = truncatedLockedCaptureHTML()                     // ~2.1k chars, locked
        let fetcher = MockArticleFetcher()
        fetcher.htmlByURL[articleURL.absoluteString] = proseHTML("nyt-unlocked", paragraphs: 8)

        let result = await ArticleResolver.resolve(
            url: articleURL, prefetchedHTML: capture, fetcher: fetcher, trustsPrefetchedHTML: true)

        // The same capture with no reachable unlock resolves to the capture itself,
        // which gives the length to beat.
        let fallback = await ArticleResolver.resolve(
            url: articleURL, prefetchedHTML: capture, fetcher: MockArticleFetcher(),
            trustsPrefetchedHTML: true)
        guard let unlocked = bodyLength(of: result), let captured = bodyLength(of: fallback) else {
            return XCTFail("expected readable results, got \(result) / \(fallback)")
        }
        XCTAssertGreaterThan(unlocked, captured, "the silent unlock must win over the truncated capture")
        // It used NYT's rule: a custom crawler User-Agent, not a plain re-fetch.
        let uaCall = fetcher.calls.first { $0.kind == .userAgent }
        XCTAssertEqual(uaCall?.userAgent, "Mozilla/5.0 (compatible; Google-InspectionTool/1.0)")
    }

    /// The capture is never LOST: when the rule's silent fetch fails outright, the
    /// resolver hands back the page the user is looking at rather than parking it.
    func testTrustedCaptureSurvivesAFailedSiteUnlock() async {
        let articleURL = URL(string: "https://www.nytimes.com/2026/07/24/science/enzymes.html")!
        let capture = truncatedLockedCaptureHTML()
        let fetcher = MockArticleFetcher()          // every fetch throws (no stubs)

        let result = await ArticleResolver.resolve(
            url: articleURL, prefetchedHTML: capture, fetcher: fetcher, trustsPrefetchedHTML: true)

        if case let .readable(_, html) = result {
            XCTAssertEqual(html, capture)
        } else {
            XCTFail("a failed unlock must fall back to the capture, got \(result)")
        }
        XCTAssertTrue(fetcher.calls.contains { $0.kind == .userAgent }, "the rule leg should have been tried")
    }

    /// Never trade DOWN: a rule fetch can be readable (no lock, over the threshold) and
    /// still be shorter than what the user already had on screen.
    func testTrustedCaptureIsNotTradedDownForAShorterUnlock() async {
        let articleURL = URL(string: "https://www.nytimes.com/2026/07/24/science/enzymes.html")!
        let capture = truncatedLockedCaptureHTML()                     // ~2.1k chars, locked
        let fetcher = MockArticleFetcher()
        fetcher.htmlByURL[articleURL.absoluteString] = proseHTML("nyt-teaser", paragraphs: 1)

        let result = await ArticleResolver.resolve(
            url: articleURL, prefetchedHTML: capture, fetcher: fetcher, trustsPrefetchedHTML: true)

        if case let .readable(_, html) = result {
            XCTAssertEqual(html, capture, "the longer capture must be kept")
        } else {
            XCTFail("expected readable, got \(result)")
        }
    }

    /// A host with no site-unlock rule has nothing the app can do that the browser
    /// couldn't: the capture is returned immediately, with no extra network at all.
    func testTrustedCaptureOnRuleFreeHostCostsNoExtraFetch() async {
        let articleURL = URL(string: "https://www.example-blog-host.com/2026/07/post")!
        XCTAssertNil(SiteUnlockRules.rule(for: articleURL), "fixture host must carry no unlock rule")
        let capture = truncatedLockedCaptureHTML()
        let fetcher = MockArticleFetcher()

        let result = await ArticleResolver.resolve(
            url: articleURL, prefetchedHTML: capture, fetcher: fetcher, trustsPrefetchedHTML: true)

        if case let .readable(_, html) = result {
            XCTAssertEqual(html, capture)
        } else {
            XCTFail("expected readable, got \(result)")
        }
        XCTAssertTrue(fetcher.calls.isEmpty, "no rule → no extra fetch")
    }

    /// When EVERY silent strategy fails (no readable result anywhere) on a host that
    /// carries a title, the resolver parks it as `.paywalled(title)` — it does NOT
    /// stop early or return readable. The archive fallback also fails here.
    func testResolverFallsAllTheWayToPaywalledWhenEveryStrategyFails() async {
        let articleURL = URL(string: "https://www.wsj.com/articles/secret_199845b1.html")!
        let fetcher = MockArticleFetcher()
        // Direct returns a titled locked teaser; every silent strategy + archive fail.
        fetcher.htmlByURL[articleURL.absoluteString] =
            "<html><head><title>WSJ Story</title></head><body><p>Lede only. Subscribe to read.</p></body></html>"
        let result = await ArticleResolver.resolve(url: articleURL, fetcher: fetcher)
        // WSJ's title survives; the body never became readable.
        XCTAssertEqual(result, .paywalled(title: "WSJ Story"))
    }
}
