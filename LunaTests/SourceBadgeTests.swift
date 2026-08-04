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

    // MARK: - Pure string derivations (initials + icon-cache keys)

    func testInitialsAndCacheKeyDerivations() {
        // sender name → chip initials
        let initials: [(String, String)] = [
            ("The Atlantic", "TA"),
            ("Ada Lovelace-Byron", "AL"),
            ("substack", "S"),
            (" …—! ", ""),
        ]
        for (name, expected) in initials {
            XCTAssertEqual(
                CarouselSourceBadge.initials(fromName: name), expected,
                "initials(fromName: \(name))")
        }

        // page URL → icon-cache key (nil = never cached)
        let keys: [(String, String?)] = [
            ("https://WWW.TheVerge.com/x", "theverge.com"),
            ("http://news.bbc.co.uk/y", "news.bbc.co.uk"),
            ("lunamail://abc", nil),
            ("lunadoc://abc", nil),
        ]
        for (urlString, expected) in keys {
            XCTAssertEqual(
                SourceIconCache.cacheKey(forPageURL: URL(string: urlString)!), expected,
                "cacheKey(forPageURL: \(urlString))")
        }
    }

    func testSenderColorIsDeterministic() {
        // Dynamic providers never compare equal as objects — resolve per style.
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            XCTAssertEqual(
                CarouselSourceBadge.color(forName: "The Atlantic").resolvedColor(with: traits),
                CarouselSourceBadge.color(forName: "The Atlantic").resolvedColor(with: traits))
        }
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

    /// (page URL, head HTML) → the ranked, resolved candidate list: touch icons
    /// first, then declared size; SVG/data/mask icons never qualify; hrefs of
    /// every relative form resolve against the page.
    func testIconLinkCandidateRanking() {
        let cases: [(name: String, page: String, html: String, expected: [String])] = [
            (
                "touch icon first, then declared size",
                "https://example.com/",
                """
                <html><head>
                <link rel="icon" href="/favicon-32.png" sizes="32x32">
                <link rel="icon" href="/favicon-192.png" sizes="192x192">
                <link rel="apple-touch-icon" href="/touch.png" sizes="180x180">
                </head><body></body></html>
                """,
                [
                    "https://example.com/touch.png",
                    "https://example.com/favicon-192.png",
                    "https://example.com/favicon-32.png",
                ]
            ),
            (
                "SVG, data and mask icons are skipped",
                "https://example.com/index.html",
                """
                <html><head>
                <link rel="mask-icon" href="/pinned.svg" color="#000">
                <link rel="icon" href="/icon.svg" type="image/svg+xml">
                <link rel="icon" href="data:image/png;base64,AAAA">
                <link rel="shortcut icon" href="favicon.ico">
                <link rel="stylesheet" href="/style.css">
                </head></html>
                """,
                ["https://example.com/favicon.ico"]
            ),
            (
                "protocol-relative hrefs resolve",
                "https://example.com/",
                #"<link rel="icon" href="//cdn.example.net/i.png">"#,
                ["https://cdn.example.net/i.png"]
            ),
        ]
        for testCase in cases {
            let candidates = FaviconFetcher.iconLinkCandidates(
                inHTML: testCase.html, pageURL: URL(string: testCase.page)!)
            XCTAssertEqual(
                candidates.map(\.absoluteString), testCase.expected, testCase.name)
        }
    }
}
