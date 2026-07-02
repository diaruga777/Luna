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
