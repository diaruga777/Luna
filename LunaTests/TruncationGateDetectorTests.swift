//
//  TruncationGateDetectorTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import XCTest
@testable import Luna

/// The generous-preview paywall: a long, readable body cut off server-side with a
/// subscribe gate standing where the rest of the article should be. Modeled on
/// `theparisreview.org`, which serves ~12k characters of a ~50k-character interview —
/// no `isAccessibleForFree`, no `article:content_tier`, no JSON-LD `articleBody`, so
/// nothing but the STRUCTURE says the reader was stopped. (Real trimmed markup for the
/// same page lives in `Fixtures/Readable/parisreview-*.html`, driven by
/// `ArticleExtractionTests`; these cases pin the decision boundaries.)
final class TruncationGateDetectorTests: XCTestCase {

    private func prose(_ paragraphs: Int) -> String {
        (0..<paragraphs).map { index in
            "<p>Interview prose paragraph number \(index) running long enough to count as "
                + "real reported text rather than a caption or a byline line.</p>"
        }.joined()
    }

    /// The wall The Paris Review appends after the preview, verbatim in shape.
    private let gate = """
    <div class="paywall">
      <div class="paywall-fade"></div>
      <h1 class="h2">Want to keep reading?<br>Subscribe and save 33%.</h1>
      <a href="https://subscribe.example.com/"><h6 class="button">Subscribe Now</h6>
      <h4 class="h2" id="sign_in_title">Already a subscriber? Sign in below.</h4></a>
      <div class="paywall-form"><form><input type="email"><input type="submit" value="Sign In"></form></div>
    </div>
    """

    /// The publisher's sign-in chrome, which EVERY page on the site carries — the reason
    /// a whole-document text scan for gate wording is not usable as this signal.
    private let navChrome = """
    <nav><div id="modal_login" class="modal-fade-screen">
      <h4>Already a subscriber? Sign in.</h4>
      <form><input type="email"><input type="submit" value="Sign In"></form>
    </div></nav>
    """

    private func page(body: String) -> String {
        "<html><head><title>The Art of Fiction No. 45</title></head><body>\(body)</body></html>"
    }

    /// Every decision boundary of `showsTruncationGate(in:)` in one sweep. Each row
    /// names the shape it encodes and that name is the failure message, so a break
    /// points at the boundary that moved.
    func testTruncationGateDecisionBoundaries() {
        let cases: [(why: String, html: String, isGate: Bool)] = [
            (
                // The real shape: a preview-length body, then the wall, ending the
                // container. Sign-in chrome and a footer CTA are also present and
                // must not change the answer.
                "a gate that ends the body container after a real preview IS a truncation",
                page(body: navChrome + """
                <div id="main"><article><div class="article-body-wrap magazine paywall-base">
                  <main class="article-body">\(prose(20))</main>
                  \(gate)
                </div></article></div>
                <footer><p>Subscribe to the magazine and receive four issues a year, plus access.</p></footer>
                """),
                true
            ),
            (
                // The pre-paywall Wayback capture is the same publisher template
                // WITHOUT the wall; it must not inherit the flag from its sign-in
                // chrome.
                "the pre-paywall capture of the same page stays readable",
                page(body: navChrome + """
                <div class="article-body-wrap"><main class="article-body">\(prose(40))</main></div>
                """),
                false
            ),
            (
                // Gate WORDING on a free article (site nav) with no wall container
                // around the body.
                "sign-in chrome alone is not a gate",
                page(body: navChrome + "<article>\(prose(20))</article>"),
                false
            ),
            (
                // WSJ ships the readable post-unlock body inside the node that NAMES
                // the paywall. `ArticleExtractor` keeps such a wrapper; the detector
                // must likewise not call it a gate.
                "an unlocked body inside a paywall-named class is not a gate",
                page(body: """
                <div class="paywall PaywalledContent">
                  <h4>Already a subscriber? Sign in.</h4>
                  \(prose(20))
                </div>
                """),
                false
            ),
            (
                // An already-unlocked capture: the extension hid the overlay but left
                // the node, and the rest of the story follows it. Only a wall that
                // ENDS the container truncates.
                "a wall left behind mid-body is not a truncation",
                page(body: """
                <div class="article-body-wrap"><main class="article-body">
                  \(prose(10))\(gate)\(prose(10))
                </main></div>
                """),
                false
            ),
            (
                // A registration interstitial rendered before any prose is a
                // whole-page wall, which the existing short-body signals already own.
                "a gate ahead of the body is not a truncation",
                page(body: """
                <div class="article-body-wrap">\(gate)<main class="article-body">\(prose(20))</main></div>
                """),
                false
            ),
            (
                // Below the preview minimum the page is a stub, not a generous
                // preview — the length-based signals handle it and this detector
                // stays out of it.
                "a gate after a teaser too short to be a preview is not a truncation",
                page(body: """
                <div class="article-body-wrap"><main class="article-body"><p>A two-line teaser only.</p></main>\(gate)</div>
                """),
                false
            ),
            (
                // No wall-named container anywhere → the cheap pre-filter answers, and
                // the answer must agree with the full check.
                "a page with no wall container is never a gate",
                page(body: "<article>\(prose(30))</article>"),
                false
            ),
        ]

        for c in cases {
            XCTAssertEqual(TruncationGateDetector.showsTruncationGate(in: c.html), c.isGate, c.why)
        }
    }

    /// The point of the structural signal: the body clears every length threshold and
    /// still isn't the article.
    func testLongTruncatedBodyReadsAsPaywalledAtAnyLength() {
        let content = ArticleContent(title: "The Art of Fiction No. 45", blocks: [
            .init(
                kind: .paragraph,
                text: String(repeating: "Interview prose that reads as the real story throughout. ", count: 300),
                links: []),
        ])
        let html = page(body: """
        <div class="article-body-wrap"><main class="article-body">\(prose(20))</main>\(gate)</div>
        """)
        XCTAssertGreaterThan(content.bodyTextLength, PaywallDetector.shortBodyThreshold)
        XCTAssertTrue(PaywallDetector.looksPaywalled(content: content, html: html))
        XCTAssertFalse(ArticleExtraction.isReadableArticle(content, html: html))
        // Text-only callers (no source HTML) are unchanged — the gate lives in the markup
        // the extractor strips, so it can only be seen with the HTML in hand.
        XCTAssertFalse(PaywallDetector.looksPaywalled(content: content))
    }
}
