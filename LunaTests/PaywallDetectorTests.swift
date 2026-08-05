//
//  PaywallDetectorTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import XCTest
@testable import Luna

final class PaywallDetectorTests: XCTestCase {

    private func content(_ paragraphs: [String]) -> ArticleContent {
        ArticleContent(title: "Headline", blocks: paragraphs.map { .init(kind: .paragraph, text: $0, links: []) })
    }

    // MARK: gate markers — flagged at ANY body length

    /// theleader.com.au (ACM) failure case: a long body padded with subscription
    /// copy, but the "login or signup to continue reading" gate phrase is present.
    /// The `looksPaywalled` / `hasReadableBody` pair is asserted on the content shape
    /// here; the phrase table below covers the other gate wordings we've hit.
    func testGatePhraseFlaggedEvenWhenBodyIsLong() {
        let long = String(repeating: "Javid Ahmadi ran the 7-Eleven franchise for years before the dispute. ", count: 60)
        let article = content([
            "Javid Ahmadi: my dream is shattered as 7-Eleven Sutherland franchise agreement ends.",
            long,
            "Login or signup to continue reading",
            "Subscribe now for unlimited access. Unlimited access on the web. Breaking news alerts.",
        ])
        XCTAssertGreaterThan(article.bodyTextLength, PaywallDetector.shortBodyThreshold)
        XCTAssertTrue(article.looksPaywalled, "a gate phrase must flag a wall regardless of length")
        XCTAssertFalse(article.hasReadableBody)
    }

    /// Gate markers fire at any length — a deliberate precision-over-recall trade, so a
    /// long article that merely QUOTES one is flagged too. Locking the policy (and each
    /// wording we've actually seen) so a future change is a conscious one.
    func testGateMarkersFlagAWallAtAnyBodyLength() {
        let long = String(repeating: "Substantive reporting continues across the piece. ", count: 80)
        let phrases = [
            "Subscribe to read the rest of this exclusive report.",
            "The notice read: subscribe to continue.",
            "Login or signup to continue reading",
        ]
        for phrase in phrases {
            let text = long + " " + phrase
            XCTAssertTrue(PaywallDetector.textLooksPaywalled(text, bodyLength: text.count),
                          "gate phrase not flagged in a long body: \(phrase)")
            // The consolidated predicate must agree: length alone never rescues a gate.
            let article = content([text])
            XCTAssertGreaterThan(article.bodyTextLength, PaywallDetector.shortBodyThreshold)
            XCTAssertFalse(ArticleExtraction.isReadableArticle(article, html: nil),
                           "a quoted gate phrase flags the wall regardless of length: \(phrase)")
        }
    }

    // MARK: weak markers — only when the body is short

    func testWeakMarkerOnlyFlagsShortBody() {
        let short = "Subscribe now to support local journalism."
        XCTAssertTrue(PaywallDetector.textLooksPaywalled(short, bodyLength: short.count))
        // Same phrase in a long article (footer CTA) is NOT a wall.
        let long = String(repeating: "Substantive reporting continues across the piece. ", count: 80)
            + " Subscribe now to support local journalism."
        XCTAssertFalse(PaywallDetector.textLooksPaywalled(long, bodyLength: long.count))
    }

    // MARK: publisher-declared (HTML) signal

    func testHTMLIsAccessibleForFreeFalse() {
        XCTAssertTrue(PaywallDetector.htmlDeclaresLocked(
            #"<script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>"#))
        XCTAssertTrue(PaywallDetector.htmlDeclaresLocked(
            #"{ "isAccessibleForFree" : false }"#))   // spacing-tolerant
        XCTAssertTrue(PaywallDetector.htmlDeclaresLocked(
            #"<meta property="article:content_tier" content="locked">"#))
    }

    func testHTMLNoSignal() {
        XCTAssertFalse(PaywallDetector.htmlDeclaresLocked(
            #"<html><head><meta property="og:title" content="A Free Story"></head><body><article>…</article></body></html>"#))
        XCTAssertFalse(PaywallDetector.htmlDeclaresLocked(
            #"{"isAccessibleForFree":true}"#))
    }

    /// HTML signal flags a short wall even when the extractor stripped the CTA text: a
    /// clean body that only just clears the readable threshold can still be a teaser.
    func testLooksPaywalledUsesHTMLWhenShortBodyLooksClean() {
        let clean = content([String(repeating: "Clean prose with no subscription words at all here. ", count: 40)])
        XCTAssertLessThan(clean.bodyTextLength, PaywallDetector.shortBodyThreshold)
        XCTAssertFalse(clean.looksPaywalled)   // text alone: fine
        XCTAssertTrue(PaywallDetector.looksPaywalled(
            content: clean, html: #"{"isAccessibleForFree":false}"#))
        // Same call through the consolidated predicate: readable text-only, NOT readable
        // once the source HTML declares the lock.
        XCTAssertTrue(ArticleExtraction.isReadableArticle(clean, html: nil))
        XCTAssertFalse(ArticleExtraction.isReadableArticle(
            clean, html: #"{"isAccessibleForFree":false}"#))
    }

    /// New Statesman-shaped pages can serve the full article while keeping subscriber
    /// metadata in schema.org. A long, gate-free body should win over that stale lock —
    /// it must not force an unnecessary archive flow.
    func testLongCleanBodyBeatsPublisherLockSignal() {
        let article = content([
            String(repeating: "Reported article prose continues with enough concrete detail to read as the actual story. ", count: 70),
        ])
        XCTAssertGreaterThan(article.bodyTextLength, PaywallDetector.shortBodyThreshold)
        XCTAssertFalse(PaywallDetector.looksPaywalled(
            content: article, html: #"{"isAccessibleForFree":false}"#))
        XCTAssertTrue(ArticleExtraction.isReadableArticle(
            article, html: #"{"isAccessibleForFree":false}"#))
    }
}
