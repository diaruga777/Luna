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

    /// HTML signal flags a short wall even when the extractor stripped the CTA text.
    func testLooksPaywalledUsesHTMLWhenShortBodyLooksClean() {
        let clean = content([String(repeating: "Clean prose with no subscription words at all here. ", count: 40)])
        XCTAssertLessThan(clean.bodyTextLength, PaywallDetector.shortBodyThreshold)
        XCTAssertFalse(clean.looksPaywalled)   // text alone: fine
        XCTAssertTrue(PaywallDetector.looksPaywalled(
            content: clean, html: #"{"isAccessibleForFree":false}"#))
    }

    /// Some publishers keep `isAccessibleForFree:false` in schema.org while still serving
    /// the complete article body. For a host we can't prove is a hard paywall, a long,
    /// gate-free body should win over that stale lock (the default, content-based read).
    func testLongCleanBodyBeatsPublisherLockSignal() {
        let article = content([
            String(repeating: "Reported article prose continues with enough concrete detail to read as the actual story. ", count: 70),
        ])
        XCTAssertGreaterThan(article.bodyTextLength, PaywallDetector.shortBodyThreshold)
        XCTAssertFalse(PaywallDetector.looksPaywalled(
            content: article, html: #"{"isAccessibleForFree":false}"#))
    }

    /// New Statesman failure case: a hard-paywall host serves a LONG teaser (well over
    /// `shortBodyThreshold`) with no gate marker — the "subscribe" CTA is injected
    /// client-side (an empty `<div id="piano-paywall">`), so the schema.org lock is the
    /// only server-side signal. `trustDeclaredLock` (which the resolver passes for a known
    /// hard-paywall host) must flag it at any length so it routes to the archive bypass.
    func testTrustedDeclaredLockFlagsLongTeaser() {
        let teaser = content([
            String(repeating: "A vivid, gate-marker-free opening that runs long before the wall cuts it off. ", count: 70),
        ])
        XCTAssertGreaterThan(teaser.bodyTextLength, PaywallDetector.shortBodyThreshold)
        // Default (content-based) read lets the long body win…
        XCTAssertFalse(PaywallDetector.looksPaywalled(
            content: teaser, html: #"{"isAccessibleForFree":false}"#))
        // …but trusting the publisher lock flags the wall regardless of length.
        XCTAssertTrue(PaywallDetector.looksPaywalled(
            content: teaser, html: #"{"isAccessibleForFree":false}"#, trustDeclaredLock: true))
        XCTAssertFalse(ArticleExtraction.isReadableArticle(
            teaser, html: #"{"isAccessibleForFree":false}"#, trustDeclaredLock: true))
    }

    /// `trustDeclaredLock` only lifts the length cap on the schema.org lock — it must NOT
    /// flag a genuinely lock-free page (so a hard-paywall host that happens to serve a
    /// full, unlocked capture still reads as an article).
    func testTrustedDeclaredLockDoesNotFlagUnlockedPage() {
        let article = content([
            String(repeating: "Complete article prose with no lock declaration anywhere in the markup. ", count: 70),
        ])
        XCTAssertFalse(PaywallDetector.looksPaywalled(
            content: article, html: #"{"isAccessibleForFree":true}"#, trustDeclaredLock: true))
    }
}
