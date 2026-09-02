//
//  ArticleExtractionTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import XCTest
@testable import Luna

/// Pins the Stage-2 `ArticleExtraction` component: the one
/// `isReadableArticle(content:html:)` predicate that decides readable vs.
/// locked, driven per-site over readable and paywalled-stub fixtures
/// (nytimes / washingtonpost / wsj / smh.com.au / theparisreview / The Information).
///
/// This is the only sweep of the `Fixtures/Readable/*` corpus; it reads each
/// fixture once. `PaywallDetectorTests` pins the predicate's own decision
/// boundaries (HTML lock vs. body length, gate markers at any length) against
/// the detector that owns them. `ArticleExtractorTests` pins the
/// empty-document throw against the parser that raises it.
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
            // The locked page explicitly withholds `fullText`, but its page shell is
            // long enough to beat both readability thresholds. The readable capture
            // keeps stale premium schema while carrying a non-locked Article payload.
            ("theinformation", "https://www.theinformation.com/articles/model-security"),
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

    // MARK: - extractFromJSONLD delegates to the parser

    func testExtractFromJSONLDRecoversArticleBody() {
        let html = BypassFixtures.html("jsonld-bloomberg.html")
        let content = extraction.extractFromJSONLD(html: html, baseURL: url("https://www.bloomberg.com/x"))
        XCTAssertNotNil(content)
        // The DOM is an empty React shell; success = recovering a substantial body
        // from the JSON-LD `articleBody` (this trimmed fixture yields ~839 chars).
        XCTAssertGreaterThan(content?.bodyTextLength ?? 0, 500)
    }
}
