//
//  PaywallDetectorTests.swift
//  ClipTests
//

import ClipModels
import XCTest
@testable import Clip

final class PaywallDetectorTests: XCTestCase {

    private func content(_ paragraphs: [String]) -> ArticleContent {
        ArticleContent(title: "Headline", blocks: paragraphs.map { .init(kind: .paragraph, text: $0, links: []) })
    }

    // MARK: gate markers — flagged at ANY body length

    /// theleader.com.au (ACM) failure case: a long body padded with subscription
    /// copy, but the "login or signup to continue reading" gate phrase is present.
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

    func testSubscribeToReadIsAGate() {
        XCTAssertTrue(PaywallDetector.textLooksPaywalled(
            "Headline. Subscribe to read the rest of this exclusive report.", bodyLength: 5000))
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

    func testRealLongArticleNotFlagged() {
        let body = String(repeating: "The committee reviewed the budget and debated the proposal. ", count: 80)
        XCTAssertFalse(PaywallDetector.textLooksPaywalled(body, bodyLength: body.count))
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

    /// HTML signal flags a wall even when the extractor stripped the CTA text.
    func testLooksPaywalledUsesHTMLWhenBodyLooksClean() {
        let clean = content([String(repeating: "Clean prose with no subscription words at all here. ", count: 40)])
        XCTAssertFalse(clean.looksPaywalled)   // text alone: fine
        XCTAssertTrue(PaywallDetector.looksPaywalled(
            content: clean, html: #"{"isAccessibleForFree":false}"#))
    }
}
