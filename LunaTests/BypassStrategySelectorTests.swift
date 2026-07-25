//
//  BypassStrategySelectorTests.swift
//  LunaTests
//

import LunaPaywallBypass
import XCTest
@testable import Luna

final class BypassStrategySelectorTests: XCTestCase {
    private func url(_ string: String) -> URL { URL(string: string)! }
    private let locked = "<html><body>subscribe to continue reading</body></html>"

    func testNotPaywalledReturnsEmpty() {
        let html = "<html><body><article>" + String(repeating: "Free article. ", count: 100)
            + "</article></body></html>"
        XCTAssertEqual(BypassStrategySelector.strategies(
            for: url("https://example.com/x"), directHTML: html), [])
    }

    func testRuleHostTriesTheArchivesSilentlyThenDirectUnlock() {
        for article in ["https://www.wsj.com/articles/x", "https://www.nytimes.com/story"] {
            XCTAssertEqual(
                BypassStrategySelector.strategies(for: url(article), directHTML: locked),
                [.waybackRaw, .waybackPrePaywall, .directUnlock, .archiveToday], article)
        }
    }

    func testUnknownHostUsesArchive() {
        // Wayback (both ends of the capture history) is silent and CAPTCHA-free, so it
        // precedes the user-visible archive.today flow.
        XCTAssertEqual(
            BypassStrategySelector.strategies(
                for: url("https://unknown.example/story"), directHTML: locked),
            [.waybackRaw, .waybackPrePaywall, .archiveToday])
    }

    func testTruncatedGenerousPreviewGetsTheArchivePlan() {
        // The Paris Review shape: a long readable preview cut off server-side, with the
        // subscribe gate standing where the rest of the interview should be. No metadata
        // lock and no thin body, so ONLY the structural signal opens the plan.
        let paragraph = "<p>Interview prose paragraph running long enough to count as real "
            + "reported text rather than a caption or a byline line.</p>"
        let truncated = """
        <html><body><div class="article-body-wrap">
          <main class="article-body">\(String(repeating: paragraph, count: 20))</main>
          <div class="paywall"><h1>Want to keep reading?</h1>
            <h4>Already a subscriber? Sign in below.</h4></div>
        </div></body></html>
        """
        XCTAssertEqual(
            BypassStrategySelector.strategies(
                for: url("https://www.theparisreview.org/interviews/3810/x"),
                directHTML: truncated),
            [.waybackRaw, .waybackPrePaywall, .archiveToday])
    }

    func testRuleHostWithoutMarkersStillBypasses() {
        // delish.com is in the unlock rule table but NOT our hard-paywall list, so a
        // no-marker page yields a `.notPaywalled` gate decision — the exact case the
        // toggle-on override flips.
        let noEvidence = "<html><body><p>" + String(repeating: "short. ", count: 5) + "</p></body></html>"
        let known = url("https://www.delish.com/story")
        XCTAssertEqual(
            BypassStrategySelector.strategies(for: known, directHTML: noEvidence),
            [.waybackRaw, .waybackPrePaywall, .directUnlock, .archiveToday])
    }

    func testUnknownHostWithoutMarkersIsNotBypassed() {
        let noEvidence = "<html><body><p>" + String(repeating: "short. ", count: 5) + "</p></body></html>"
        XCTAssertEqual(
            BypassStrategySelector.strategies(
                for: url("https://randomblog.example/post"), directHTML: noEvidence),
            [])
    }
}
