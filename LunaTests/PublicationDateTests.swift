//
//  PublicationDateTests.swift
//  LunaTests
//

import LunaFetch
import LunaHTMLClassification
import LunaPaywallBypass
import XCTest
@testable import Luna

/// Covers the publication-date scan that decides whether the `.waybackPrePaywall`
/// long shot is worth scheduling — the metadata heuristic that keeps a save of
/// today's paywalled news from paying for a Wayback index lookup that provably
/// cannot help it.
final class PublicationDateTests: XCTestCase {

    private let reference = ISO8601DateFormatter().date(from: "2026-08-01T12:00:00Z")!

    private func page(_ head: String) -> String {
        "<html><head><title>A story</title>\(head)</head><body><p>Body.</p></body></html>"
    }

    // MARK: - Declaration shapes

    func testOpenGraphPublishedTime() {
        let html = page(#"<meta property="article:published_time" content="2026-07-30T09:15:00Z">"#)
        XCTAssertEqual(PublicationDate.declared(inHTML: html),
                       ISO8601DateFormatter().date(from: "2026-07-30T09:15:00Z"))
    }

    func testAttributeOrderReversed() {
        // Plenty of CMSes emit content= before property=.
        let html = page(#"<meta content="2026-07-30T09:15:00Z" property="article:published_time">"#)
        XCTAssertEqual(PublicationDate.declared(inHTML: html),
                       ISO8601DateFormatter().date(from: "2026-07-30T09:15:00Z"))
    }

    func testJSONLDDatePublished() {
        let html = page(#"<script type="application/ld+json">"#
            + #"{"@type":"NewsArticle","datePublished":"2019-03-04T00:00:00+00:00"}</script>"#)
        XCTAssertEqual(PublicationDate.declared(inHTML: html),
                       ISO8601DateFormatter().date(from: "2019-03-04T00:00:00Z"))
    }

    func testFractionalSecondsParsed() {
        let html = page(#"<meta property="article:published_time" content="2026-07-30T09:15:00.482Z">"#)
        XCTAssertNotNil(PublicationDate.declared(inHTML: html))
    }

    func testBareDayParsed() {
        let html = page(#"<meta name="pubdate" content="2011-06-02">"#)
        XCTAssertEqual(PublicationDate.declared(inHTML: html),
                       ISO8601DateFormatter().date(from: "2011-06-02T00:00:00Z"))
    }

    func testTimeElementIsTheLastResort() {
        let html = page("") .replacingOccurrences(
            of: "<body>", with: #"<body><time datetime="2020-01-05T00:00:00Z">Jan 5</time>"#)
        XCTAssertEqual(PublicationDate.declared(inHTML: html),
                       ISO8601DateFormatter().date(from: "2020-01-05T00:00:00Z"))
    }

    func testExplicitMetaBeatsATimeElement() {
        // A related-story stamp in a <time> must not outrank the page's own declaration.
        let html = page(#"<meta property="article:published_time" content="2026-07-30T09:15:00Z">"#)
            .replacingOccurrences(of: "<body>", with: #"<body><time datetime="2010-01-01T00:00:00Z">old</time>"#)
        XCTAssertEqual(PublicationDate.declared(inHTML: html),
                       ISO8601DateFormatter().date(from: "2026-07-30T09:15:00Z"))
    }

    func testUndatedPageDeclaresNothing() {
        XCTAssertNil(PublicationDate.declared(inHTML: page("")))
    }

    func testUnparseableValueDeclaresNothing() {
        XCTAssertNil(PublicationDate.declared(
            inHTML: page(#"<meta property="article:published_time" content="last Tuesday">"#)))
    }

    // MARK: - The age question

    func testRecentArticleProvesYoung() {
        let html = page(#"<meta property="article:published_time" content="2026-07-30T09:15:00Z">"#)
        XCTAssertTrue(PublicationDate.provesYounger(
            than: ArticleFetcher.prePaywallCaptureMinimumAge, html: html, now: reference))
    }

    func testOldArticleDoesNotProveYoung() {
        let html = page(#"<meta property="article:published_time" content="1969-06-02T00:00:00Z">"#)
        XCTAssertFalse(PublicationDate.provesYounger(
            than: ArticleFetcher.prePaywallCaptureMinimumAge, html: html, now: reference))
    }

    func testUndatedPageNeverProvesYoung() {
        // Absence of evidence is not evidence: an undated page must keep every strategy.
        XCTAssertFalse(PublicationDate.provesYounger(
            than: ArticleFetcher.prePaywallCaptureMinimumAge, html: page(""), now: reference))
    }

    // MARK: - What the selector does with it

    private let paywalledMarkup =
        #"<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>"#

    func testSelectorDropsThePrePaywallLegForARecentArticle() {
        let url = URL(string: "https://www.example-daily-news.com/2026/07/30/story")!
        let html = page(paywalledMarkup
            + #"<meta property="article:published_time" content="2026-07-30T09:15:00Z">"#)
        let strategies = BypassStrategySelector.strategies(for: url, directHTML: html, now: reference)
        XCTAssertTrue(strategies.contains(.waybackRaw))
        XCTAssertFalse(strategies.contains(.waybackPrePaywall),
                       "a story published two days ago was walled from publication")
    }

    func testSelectorKeepsThePrePaywallLegForAnOldArticle() {
        let url = URL(string: "https://www.example-daily-news.com/1969/06/02/story")!
        let html = page(paywalledMarkup
            + #"<meta property="article:published_time" content="1969-06-02T00:00:00Z">"#)
        let strategies = BypassStrategySelector.strategies(for: url, directHTML: html, now: reference)
        XCTAssertTrue(strategies.contains(.waybackPrePaywall),
                      "a 1969 piece could well have been free before the wall went up")
    }

    func testSelectorKeepsThePrePaywallLegWhenThePageIsUndated() {
        let url = URL(string: "https://www.example-daily-news.com/interviews/45")!
        let html = page(paywalledMarkup)
        let strategies = BypassStrategySelector.strategies(for: url, directHTML: html, now: reference)
        XCTAssertTrue(strategies.contains(.waybackPrePaywall))
    }

    func testSelectorKeepsThePrePaywallLegWhenThePageNeverArrived() {
        // A hard-paywall host that 401s gives us no markup to date it by, so the leg
        // stays scheduled — the fetcher's own capture-age check is the backstop there.
        let url = URL(string: "https://www.wsj.com/politics/policy/story-1e34a78f")!
        let strategies = BypassStrategySelector.strategies(for: url, directHTML: nil, now: reference)
        XCTAssertTrue(strategies.contains(.waybackPrePaywall))
    }
}
