//
//  ArticleContentPaywallTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import XCTest
@testable import Luna

/// Verifies the paywall-stub detection that decides whether extracted text is a
/// real article or a subscription wall / crawler teaser (and so must fall back to
/// a full archive). Uses the actual shapes seen from FT and WSJ.
final class ArticleContentPaywallTests: XCTestCase {

    private func content(_ paragraphs: [String], title: String = "Headline") -> ArticleContent {
        ArticleContent(
            title: title,
            blocks: paragraphs.map { .init(kind: .paragraph, text: $0, links: []) })
    }

    /// FT's interstitial: headline echoed, then subscription marketing.
    func testFinancialTimesMarketingStubIsPaywalled() {
        let ft = content([
            "US and Iran sign deal as Donald Trump vows to release frozen funds and ease sanctions",
            "Try unlimited access",
            "Then AU$99 per month. Complete digital access to quality FT journalism on any "
                + "device. Cancel anytime during your trial.",
            "Global news & analysis. Expert opinion. FT App on Android & iOS. 20+ curated newsletters.",
        ])
        XCTAssertTrue(ft.looksPaywalled)
        XCTAssertFalse(ft.hasReadableBody)
    }

    /// WSJ's Wayback snapshot: lede + one quote wrapped in Dow Jones boilerplate.
    func testWSJWaybackTeaserIsPaywalled() {
        let wsj = content([
            "This copy is for your personal, non-commercial use only. Distribution and use of "
                + "this material are governed by our Subscriber Agreement and by copyright law.",
            "Apple plans to raise prices on its products to offset the surging costs of memory "
                + "and storage chips, Chief Executive Tim Cook said.",
            "“Unfortunately, price increases are unavoidable,” he said.",
            "Copyright ©2026 Dow Jones & Company, Inc. All Rights Reserved.",
        ])
        XCTAssertTrue(wsj.looksPaywalled)
        XCTAssertFalse(wsj.hasReadableBody)
    }

    /// A long real article that merely MENTIONS subscribing must not be flagged.
    func testLongArticleMentioningSubscribeIsNotPaywalled() {
        let body = String(repeating: "The newsroom debated whether to subscribe to the wire service. ", count: 60)
        let article = content([body])
        XCTAssertGreaterThanOrEqual(article.bodyTextLength, PaywallDetector.shortBodyThreshold)
        XCTAssertFalse(article.looksPaywalled)
        XCTAssertTrue(article.hasReadableBody)
    }

    /// A normal article with no wall language reads fine. Body clears the
    /// `readableBodyThreshold` (1200): "Real reporting and analysis here. " is
    /// 34 chars × 40 = 1360.
    func testOrdinaryArticleIsReadable() {
        let article = content([String(repeating: "Real reporting and analysis here. ", count: 40)])
        XCTAssertFalse(article.looksPaywalled)
        XCTAssertTrue(article.hasReadableBody)
    }

    /// Too little text is not readable regardless of wall language.
    func testTooShortIsNotReadable() {
        let stub = content(["Subscribe to read the full story."])
        XCTAssertFalse(stub.hasReadableBody)
    }

    // MARK: - PaywallDetector.htmlDeclaresLocked / looksPaywalled(content:html:)

    func testDetectsPublisherPaywallSchema() {
        XCTAssertTrue(PaywallDetector.htmlDeclaresLocked(#"{"isAccessibleForFree":false}"#))
        XCTAssertFalse(PaywallDetector.htmlDeclaresLocked(#"{"isAccessibleForFree":true}"#))
    }

    func testPublisherLockRejectsShortCleanBodiesOnly() {
        let short = content([
            String(repeating: "Clean prose with no subscription words at all here. ", count: 40),
        ], title: "Story")
        XCTAssertLessThan(short.bodyTextLength, PaywallDetector.shortBodyThreshold)
        XCTAssertTrue(PaywallDetector.looksPaywalled(
            content: short, html: #"{"isAccessibleForFree":false}"#))

        let long = content([
            String(repeating: "Reported article prose continues with enough concrete detail to read as the actual story. ", count: 70),
        ], title: "Story")
        XCTAssertGreaterThan(long.bodyTextLength, PaywallDetector.shortBodyThreshold)
        XCTAssertFalse(PaywallDetector.looksPaywalled(
            content: long, html: #"{"isAccessibleForFree":false}"#))
        XCTAssertTrue(ArticleExtraction.isReadableArticle(
            long, html: #"{"isAccessibleForFree":false}"#))
    }
}
