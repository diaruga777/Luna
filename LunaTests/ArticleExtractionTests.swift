//
//  ArticleExtractionTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import XCTest
@testable import Luna

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
            // The generous-preview shape, from the real pages: the live interview's
            // ~5.7k-character preview (far over every length threshold, no metadata lock)
            // cut off by the `.paywall` gate, against the pre-paywall Wayback capture of
            // the same interview. Only `TruncationGateDetector` separates these two.
            ("parisreview", "https://www.theparisreview.org/interviews/3810/the-art-of-fiction-no-45-john-steinbeck"),
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

    // MARK: - HTML lock signal policy

    /// A clean body that only just clears the readable threshold can still be a teaser
    /// whose CTA was stripped. The source HTML lock rejects that short/medium shape.
    func testHTMLLockRejectsShortCleanBody() {
        let cleanBody = String(repeating: "Clean prose with no subscription words at all here. ", count: 40)
        let content = ArticleContent(title: "Story", blocks: [
            .init(kind: .paragraph, text: cleanBody, links: []),
        ])
        XCTAssertLessThan(content.bodyTextLength, PaywallDetector.shortBodyThreshold)
        // Text-only: readable.
        XCTAssertTrue(ArticleExtraction.isReadableArticle(content, html: nil))
        // With the lock-declaring HTML: NOT readable.
        XCTAssertFalse(ArticleExtraction.isReadableArticle(
            content, html: #"{"isAccessibleForFree":false}"#))
    }

    /// Some publishers serve complete subscriber-marked stories in the initial HTML.
    /// Once the extracted body is long and has no gate language, the stale lock signal
    /// must not force an unnecessary archive flow.
    func testLongCleanBodyBeatsHTMLLock() {
        let body = String(repeating: "Clean reported prose continues with enough specific article detail here. ", count: 70)
        let content = ArticleContent(title: "Story", blocks: [
            .init(kind: .paragraph, text: body, links: []),
        ])
        XCTAssertGreaterThan(content.bodyTextLength, PaywallDetector.shortBodyThreshold)
        XCTAssertTrue(ArticleExtraction.isReadableArticle(
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
        // The DOM is an empty React shell; success = recovering a substantial body
        // from the JSON-LD `articleBody` (this trimmed fixture yields ~839 chars).
        XCTAssertGreaterThan(content?.bodyTextLength ?? 0, 500)
    }
}
