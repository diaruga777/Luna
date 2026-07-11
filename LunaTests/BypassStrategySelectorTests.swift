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

    func testRuleHostGoesDirectUnlockThenArchive() {
        for article in ["https://www.wsj.com/articles/x", "https://www.nytimes.com/story"] {
            XCTAssertEqual(
                BypassStrategySelector.strategies(for: url(article), directHTML: locked),
                [.directUnlock, .archiveToday], article)
        }
    }

    func testUnknownHostUsesArchive() {
        XCTAssertEqual(
            BypassStrategySelector.strategies(
                for: url("https://unknown.example/story"), directHTML: locked),
            [.archiveToday])
    }

    func testRuleHostWithoutMarkersStillBypasses() {
        // delish.com is in the unlock rule table but NOT our hard-paywall list, so a
        // no-marker page yields a `.notPaywalled` gate decision — the exact case the
        // toggle-on override flips.
        let noEvidence = "<html><body><p>" + String(repeating: "short. ", count: 5) + "</p></body></html>"
        let known = url("https://www.delish.com/story")
        XCTAssertEqual(
            BypassStrategySelector.strategies(for: known, directHTML: noEvidence),
            [.directUnlock, .archiveToday])
    }

    func testUnknownHostWithoutMarkersIsNotBypassed() {
        let noEvidence = "<html><body><p>" + String(repeating: "short. ", count: 5) + "</p></body></html>"
        XCTAssertEqual(
            BypassStrategySelector.strategies(
                for: url("https://randomblog.example/post"), directHTML: noEvidence),
            [])
    }
}
