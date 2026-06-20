//
//  BypassStrategySelectorTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Exercises the pure `BypassStrategySelector`: given (host, HTML) it returns the
/// ordered strategy list, with the de-dup + silent-before-webview + archive-last
/// invariants enforced.
final class BypassStrategySelectorTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    private let lockedHTML = "<html><body><p>subscribe to continue. "
        + "<meta property=\"article:content_tier\" content=\"locked\"></p></body></html>"
    private let readableFreeHTML = "<html><body><article>"
        + String(repeating: "<p>Ordinary free article prose here. </p>", count: 20)
        + "</article></body></html>"

    func testNotPaywalledReturnsEmpty() {
        XCTAssertEqual(
            BypassStrategySelector.strategies(for: url("https://example.com/x"), directHTML: readableFreeHTML),
            [])
    }

    func testNilDirectHTMLStillSelects() {
        // Direct fetch failed — we can't prove it's free, so select a strategy list.
        let result = BypassStrategySelector.strategies(for: url("https://unknown.example/x"), directHTML: nil)
        XCTAssertFalse(result.isEmpty)
        XCTAssertEqual(result.last, .archiveToday)
    }

    func testPerHostRuleUsedVerbatimOrder() {
        // NYT's rule leads with the trailing-dot trick.
        let result = BypassStrategySelector.strategies(
            for: url("https://www.nytimes.com/2026/06/20/story.html"), directHTML: lockedHTML)
        XCTAssertEqual(result.first, .trailingDotHost)
        XCTAssertEqual(result.last, .archiveToday)
    }

    func testGenericMeteredBranchIncludesClientTricks() {
        let result = BypassStrategySelector.strategies(for: url("https://unknown.example/x"), directHTML: lockedHTML)
        // A hard `locked` declaration drops cookie/origin tricks.
        XCTAssertFalse(result.contains(.freshSession))
        XCTAssertFalse(result.contains(.trailingDotHost))
    }

    func testGenericNonLockedBranchKeepsClientTricks() {
        let meteredHTML = "<html><body><p>subscribe to continue reading this article</p></body></html>"
        let result = BypassStrategySelector.strategies(for: url("https://unknown.example/x"), directHTML: meteredHTML)
        XCTAssertTrue(result.contains(.freshSession))
        XCTAssertTrue(result.contains(.trailingDotHost))
    }

    func testJSONLDPresenceTogglesJsonLDBody() {
        let bodyHTML = "<html><body><p>subscribe to continue</p>"
            + "<script type=\"application/ld+json\">{\"articleBody\":\"x\"}</script></body></html>"
        let withBody = BypassStrategySelector.strategies(for: url("https://unknown.example/x"), directHTML: bodyHTML)
        XCTAssertTrue(withBody.contains(.jsonLDBody))

        let noBodyHTML = "<html><body><p>subscribe to continue</p></body></html>"
        let withoutBody = BypassStrategySelector.strategies(for: url("https://unknown.example/x"), directHTML: noBodyHTML)
        XCTAssertFalse(withoutBody.contains(.jsonLDBody))
    }

    func testSilentStrategiesPrecedeWebViewOnesAndArchiveLast() {
        let result = BypassStrategySelector.strategies(for: url("https://www.nytimes.com/x"), directHTML: lockedHTML)
        let firstWebViewIndex = result.firstIndex { !$0.runsSilently }
        if let firstWebViewIndex {
            // Everything before the first WKWebView strategy must be silent.
            XCTAssertTrue(result[..<firstWebViewIndex].allSatisfy(\.runsSilently))
        }
        XCTAssertEqual(result.last, .archiveToday)
        // archive.today appears exactly once.
        XCTAssertEqual(result.filter { $0 == .archiveToday }.count, 1)
    }

    func testNoDuplicateStrategies() {
        let result = BypassStrategySelector.strategies(for: url("https://unknown.example/x"), directHTML: lockedHTML)
        let descriptions = result.map { String(describing: $0) }
        XCTAssertEqual(descriptions.count, Set(descriptions).count)
    }

    func testSubdomainMatchesRule() {
        let result = BypassStrategySelector.strategies(
            for: url("https://cooking.nytimes.com/recipe"), directHTML: lockedHTML)
        XCTAssertEqual(result.first, .trailingDotHost)
    }
}
