//
//  ArticleExtractionTests.swift
//  ClipTests
//

import ClipModels
import XCTest
@testable import Clip

/// Exercises the Stage-2 `ArticleExtraction` component: the single
/// `isReadableArticle(content:html:)` predicate that consolidated the three former
/// duplicate readable/locked checks, driven per-site over readable + paywalled-stub
/// fixtures (nytimes / washingtonpost / wsj / smh.com.au), plus the HTML-lock
/// false-negative guard.
final class ArticleExtractionTests: XCTestCase {

    private let extraction = ArticleExtraction()

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    private func fixture(_ name: String) -> String {
        BypassFixtures.html("Readable/\(name)")
    }

    /// Extracts a fixture and returns (content, sourceHTML) for the predicate.
    private func extract(_ name: String, _ urlString: String) -> (ArticleContent, String)? {
        let html = fixture(name)
        guard let content = try? extraction.extract(html: html, baseURL: url(urlString)) else { return nil }
        return (content, html)
    }

    // MARK: - Per-site readable + paywalled-stub table

    /// Each readable variant extracts a real body AND `isReadableArticle` is true; each
    /// paywalled variant `isReadableArticle` is false — the predicate proven per-site.
    func testPerSiteReadablePredicate() {
        let cases: [(site: String, host: String)] = [
            ("nytimes", "https://www.nytimes.com/2026/06/20/story.html"),
            ("washingtonpost", "https://www.washingtonpost.com/2026/06/20/story.html"),
            ("wsj", "https://www.wsj.com/articles/apple-prices"),
            ("smh", "https://www.smh.com.au/national/story-20260620.html"),
        ]
        for c in cases {
            guard let (readable, readableHTML) = extract("\(c.site)-readable.html", c.host) else {
                return XCTFail("\(c.site): readable fixture failed to extract")
            }
            XCTAssertGreaterThanOrEqual(readable.bodyTextLength, ArticleContent.readableBodyThreshold,
                                        "\(c.site): readable body should clear the threshold")
            XCTAssertTrue(ArticleExtraction.isReadableArticle(readable, html: readableHTML),
                          "\(c.site): readable variant must be readable")

            guard let (locked, lockedHTML) = extract("\(c.site)-paywalled.html", c.host) else {
                return XCTFail("\(c.site): paywalled fixture failed to extract")
            }
            XCTAssertFalse(ArticleExtraction.isReadableArticle(locked, html: lockedHTML),
                           "\(c.site): paywalled stub must NOT be readable")
        }
    }

    // MARK: - The HTML lock signal can't be bypassed by a text-only path

    /// A long, clean body (text alone reads fine) but the source HTML declares the
    /// publisher lock — `isReadableArticle(content:html:)` must still reject it (the
    /// false-negative guard: the lock can't be skipped by reaching for a text path).
    func testHTMLLockRejectsEvenWhenBodyTextLooksClean() {
        let cleanBody = String(repeating: "Clean prose with no subscription words at all here. ", count: 40)
        let content = ArticleContent(title: "Story", blocks: [
            .init(kind: .paragraph, text: cleanBody, links: []),
        ])
        // Text-only: readable.
        XCTAssertTrue(ArticleExtraction.isReadableArticle(content, html: nil))
        // With the lock-declaring HTML: NOT readable.
        XCTAssertFalse(ArticleExtraction.isReadableArticle(
            content, html: #"{"isAccessibleForFree":false}"#))
    }

    // MARK: - Long-article-quoting-a-gate-phrase policy (locked deliberately)

    /// A long article that QUOTES a full gate phrase is flagged as a wall (gate markers
    /// fire at any length — a deliberate precision-over-recall trade). Locking the
    /// policy so a future change is a conscious one.
    func testLongArticleQuotingGatePhraseIsFlagged() {
        let long = String(repeating: "Substantive reporting continues across the piece. ", count: 80)
        let content = ArticleContent(title: "Story", blocks: [
            .init(kind: .paragraph, text: long + " The notice read: subscribe to continue.", links: []),
        ])
        XCTAssertGreaterThan(content.bodyTextLength, PaywallDetector.shortBodyThreshold)
        XCTAssertFalse(ArticleExtraction.isReadableArticle(content, html: nil),
                       "a quoted gate phrase flags the wall regardless of length (locked policy)")
    }

    // MARK: - extract + extractFromJSONLD delegate to the parser

    func testExtractThrowsOnEmptyDocument() {
        XCTAssertThrowsError(try extraction.extract(
            html: "<html><head></head><body></body></html>", baseURL: url("https://e.com/")))
    }

    func testExtractFromJSONLDRecoversArticleBody() {
        let html = BypassFixtures.html("jsonld-bloomberg.html")
        let content = extraction.extractFromJSONLD(html: html, baseURL: url("https://www.bloomberg.com/x"))
        XCTAssertNotNil(content)
        XCTAssertGreaterThan(content?.bodyTextLength ?? 0, ArticleContent.readableBodyThreshold)
    }
}
