//
//  SourceBadgeTests.swift
//  LunaTests
//
//  The mini-card scrub chips' source identity: the item → fallback-badge
//  mapping, sender-initials derivation, favicon <link> candidate ranking,
//  and the icon cache's host keying.
//

import LunaDesignSystem
import LunaFetch
import LunaModels
import XCTest

@testable import Luna

final class SourceBadgeTests: XCTestCase {

    // MARK: - Initials

    func testInitialsTakeFirstTwoWords() {
        XCTAssertEqual(CarouselSourceBadge.initials(fromName: "The Atlantic"), "TA")
        XCTAssertEqual(CarouselSourceBadge.initials(fromName: "Ada Lovelace-Byron"), "AL")
    }

    func testInitialsSingleWordAndEmpty() {
        XCTAssertEqual(CarouselSourceBadge.initials(fromName: "substack"), "S")
        XCTAssertEqual(CarouselSourceBadge.initials(fromName: " …—! "), "")
    }

    func testSenderColorIsDeterministic() {
        XCTAssertEqual(
            CarouselSourceBadge.color(forName: "The Atlantic"),
            CarouselSourceBadge.color(forName: "The Atlantic"))
    }

    // MARK: - Fallback badges

    private func fixture(
        url: String,
        captureSource: CaptureSource? = nil,
        channelName: String? = nil,
        documentType: String? = nil
    ) -> ReadingListItem {
        ReadingListItem(
            seed: "badge-\(url)", urlString: url, title: "T", dateAdded: Date(timeIntervalSince1970: 0),
            documentType: documentType, channelName: channelName, captureSource: captureSource)
    }

    func testEmailWithSenderGetsInitialsBadge() {
        let item = fixture(
            url: "lunamail://msg-1", captureSource: .email, channelName: "The Atlantic")
        XCTAssertEqual(ArticleSourceBadge.fallback(for: item), .sender("The Atlantic"))
    }

    func testEmailWithoutSenderGetsMailSymbol() {
        let item = fixture(url: "lunamail://msg-2", captureSource: .email)
        XCTAssertEqual(ArticleSourceBadge.fallback(for: item), .symbol("envelope.fill"))
    }

    /// Legacy email imports predate `captureSource`; the synthetic scheme
    /// still routes them to the mail badge.
    func testLegacyLunamailSchemeCountsAsEmail() {
        let item = fixture(url: "lunamail://msg-3")
        XCTAssertEqual(ArticleSourceBadge.fallback(for: item), .symbol("envelope.fill"))
    }

    func testDocumentGetsDocumentSymbol() {
        let item = fixture(url: "lunadoc://doc-1", documentType: "pdf")
        XCTAssertEqual(ArticleSourceBadge.fallback(for: item), .symbol("doc.text.fill"))
    }

    func testWebSaveGetsGlobeAndWantsFavicon() {
        let item = fixture(url: "https://www.theverge.com/some-article")
        XCTAssertEqual(ArticleSourceBadge.fallback(for: item), .symbol("globe"))
        XCTAssertTrue(ArticleSourceBadge.wantsFavicon(item))
    }

    func testSyntheticSchemesNeverWantFavicons() {
        XCTAssertFalse(ArticleSourceBadge.wantsFavicon(fixture(url: "lunamail://m", captureSource: .email)))
        XCTAssertFalse(ArticleSourceBadge.wantsFavicon(fixture(url: "lunadoc://d", documentType: "pdf")))
    }

    // MARK: - Favicon <link> candidates

    func testIconCandidatesPreferTouchIconsThenDeclaredSize() {
        let html = """
        <html><head>
        <link rel="icon" href="/favicon-32.png" sizes="32x32">
        <link rel="icon" href="/favicon-192.png" sizes="192x192">
        <link rel="apple-touch-icon" href="/touch.png" sizes="180x180">
        </head><body></body></html>
        """
        let candidates = FaviconFetcher.iconLinkCandidates(
            inHTML: html, pageURL: URL(string: "https://example.com/")!)
        XCTAssertEqual(candidates.map(\.absoluteString), [
            "https://example.com/touch.png",
            "https://example.com/favicon-192.png",
            "https://example.com/favicon-32.png",
        ])
    }

    func testIconCandidatesSkipSVGDataAndMaskIcons() {
        let html = """
        <html><head>
        <link rel="mask-icon" href="/pinned.svg" color="#000">
        <link rel="icon" href="/icon.svg" type="image/svg+xml">
        <link rel="icon" href="data:image/png;base64,AAAA">
        <link rel="shortcut icon" href="favicon.ico">
        <link rel="stylesheet" href="/style.css">
        </head></html>
        """
        let candidates = FaviconFetcher.iconLinkCandidates(
            inHTML: html, pageURL: URL(string: "https://example.com/index.html")!)
        XCTAssertEqual(candidates.map(\.absoluteString), ["https://example.com/favicon.ico"])
    }

    func testIconCandidatesResolveProtocolRelativeHrefs() {
        let html = #"<link rel="icon" href="//cdn.example.net/i.png">"#
        let candidates = FaviconFetcher.iconLinkCandidates(
            inHTML: html, pageURL: URL(string: "https://example.com/")!)
        XCTAssertEqual(candidates.map(\.absoluteString), ["https://cdn.example.net/i.png"])
    }

    // MARK: - Icon cache keys

    func testCacheKeyStripsWWWAndLowercases() {
        XCTAssertEqual(
            SourceIconCache.cacheKey(forPageURL: URL(string: "https://WWW.TheVerge.com/x")!),
            "theverge.com")
        XCTAssertEqual(
            SourceIconCache.cacheKey(forPageURL: URL(string: "http://news.bbc.co.uk/y")!),
            "news.bbc.co.uk")
    }

    func testCacheKeyRejectsSyntheticSchemes() {
        XCTAssertNil(SourceIconCache.cacheKey(forPageURL: URL(string: "lunamail://abc")!))
        XCTAssertNil(SourceIconCache.cacheKey(forPageURL: URL(string: "lunadoc://abc")!))
    }
}
