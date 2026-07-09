//
//  ArticleResolverTests.swift
//  LunaTests
//

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
        XCTAssertEqual(result, .unreadable)
    }

    func testNothingReachableIsUnreadable() {
        let result = ArticleResolver.resolution(direct: nil, archived: nil)
        XCTAssertEqual(result, .unreadable)
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

    /// Toggle ON + a site unlock rule (WSJ → Referer:Drudge): the resolver runs the
    /// rule's silent request technique. Here the Drudge-referer fetch returns the full
    /// article, so it wins before any browser-tier / archive fallback.
    func testResolverSilentRefererUnlockWinsForWSJ() async {
        let articleURL = URL(string: "https://www.wsj.com/articles/x_199845b1.html")!
        let fetcher = MockArticleFetcher()
        fetcher.htmlByURL[articleURL.absoluteString] = lockedHTML             // direct read = locked
        fetcher.refererHTMLByURL[articleURL.absoluteString] = readableHTML("drudge")  // referer read = full

        let result = await ArticleResolver.resolve(
            url: articleURL, fetcher: fetcher, nonArchiveBypass: true)
        if case .readable = result {} else { return XCTFail("expected readable, got \(result)") }
        // The silent leg used a Drudge-referer fetch (WSJ's rule), not a crawler UA.
        let refererCall = fetcher.calls.first { $0.kind == .referer }
        XCTAssertEqual(refererCall?.referer, "https://www.drudgereport.com/")
    }

    /// Toggle ON + WSJ, but the silent Referer fetch stays locked and there's no
    /// JSON-LD body: the resolver parks it under its title for the browser-tier /
    /// archive flow rather than returning a locked page.
    func testResolverParksWhenSilentRefererStaysLocked() async {
        let articleURL = URL(string: "https://www.wsj.com/articles/x_199845b1.html")!
        let fetcher = MockArticleFetcher()
        // Both the direct AND the Drudge-referer fetch return the same locked teaser.
        fetcher.htmlByURL[articleURL.absoluteString] = lockedHTML

        let result = await ArticleResolver.resolve(
            url: articleURL, fetcher: fetcher, nonArchiveBypass: true)
        XCTAssertEqual(result, .paywalled(title: "NYT Headline"))   // lockedHTML's title
        XCTAssertTrue(fetcher.calls.contains { $0.kind == .referer })
    }

    /// A long, gate-marker-free body that ALSO still carries the publisher's schema.org
    /// lock — the shape a hard-paywall wall serves when it truncates a long teaser and
    /// injects its "subscribe" CTA client-side, and the shape of the Safari "Read in Luna"
    /// hand-off / a free publisher that mislabels its JSON-LD.
    private func readableButLockedHTML(_ marker: String) -> String {
        let paragraph = "<p>" + String(repeating: "An ordinary readable sentence about \(marker). ", count: 30) + "</p>"
        return "<html><head><title>Real \(marker)</title>"
            + #"<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>"#
            + "</head><body><article>\(paragraph)\(paragraph)</article></body></html>"
    }

    /// New Statesman failure case: a hard-paywall host serves a LONG (over the readable
    /// threshold), gate-marker-free teaser that still declares a schema.org lock — the
    /// "subscribe" CTA is injected client-side (an empty `<div id="piano-paywall">`), so
    /// that flag is the only server-side signal. The resolver must NOT accept the teaser;
    /// it parks under the page title for the archive bypass instead of returning readable.
    func testHardPaywallHostLongTeaserParksDespiteNoGateMarker() async {
        let articleURL = URL(string: "https://www.newstatesman.com/world/asia/2026/07/in-hong-kong-i-saw-the-coming-chinese-century")!
        let html = readableButLockedHTML("newstatesman")
        let fetcher = MockArticleFetcher()
        fetcher.htmlByURL[articleURL.absoluteString] = html

        let result = await ArticleResolver.resolve(
            url: articleURL, fetcher: fetcher,
            nonArchiveBypass: true, trustsPrefetchedHTML: false)
        XCTAssertEqual(result, .paywalled(title: "Real newstatesman"))
    }

    /// The lock is distrusted ONLY for KNOWN hard-paywall hosts. An unknown host that
    /// serves a long body while carrying a stale schema.org lock still resolves directly —
    /// the "publisher mislabels a free article" case the length cap exists to protect.
    func testUnknownHostLongBodyBeatsStaleSchemaLock() async {
        let articleURL = URL(string: "https://blog.example.org/2026/07/a-free-essay")!
        let html = readableButLockedHTML("freeblog")
        let fetcher = MockArticleFetcher()
        fetcher.htmlByURL[articleURL.absoluteString] = html

        let result = await ArticleResolver.resolve(
            url: articleURL, fetcher: fetcher,
            nonArchiveBypass: true, trustsPrefetchedHTML: false)
        if case .readable = result {} else { XCTFail("unknown-host long body should be readable, got \(result)") }
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
            nonArchiveBypass: true, trustsPrefetchedHTML: false)
        if case .readable = parked { XCTFail("short untrusted prefetch must not bypass the schema lock") }

        let result = await ArticleResolver.resolve(
            url: articleURL, prefetchedHTML: html, fetcher: MockArticleFetcher(),
            nonArchiveBypass: true, trustsPrefetchedHTML: true)
        if case .readable = result {} else { XCTFail("trusted prefetch should be readable, got \(result)") }
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
        let result = await ArticleResolver.resolve(
            url: articleURL, fetcher: fetcher, nonArchiveBypass: true)
        // WSJ's title survives; the body never became readable.
        XCTAssertEqual(result, .paywalled(title: "WSJ Story"))
    }
}
