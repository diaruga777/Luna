//
//  ArchiveWebPreStageTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Exercises the pure `ArchiveWebReaderViewController.webPreStageURLs(for:)` ordering
/// — the WKWebView pre-stage list that generalizes the former NYT-only trailing-dot
/// pre-stage. Only the JS-rendered strategies (trailing-dot host + third-party reader
/// pages) become pre-stage URLs; silent strategies and archive.today are excluded.
final class ArchiveWebPreStageTests: XCTestCase {

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    /// NYT's rule leads with a SILENT trailing-dot strategy, so it already ran in the
    /// background path. A trailing-dot origin trick returns the same wall in a browser
    /// (it doesn't benefit from a JS retry), so the plan OMITS it from the WKWebView
    /// pre-stages — NYT goes silent-trailing-dot → (fail) → third-party pages →
    /// archive.today, skipping the ~9s redundant trailing-dot pre-stage (the speed fix).
    func testNYTOmitsTrailingDotAndLeadsWithThirdPartyPages() {
        let stages = ArchiveWebReaderViewController.webPreStageURLs(
            for: url("https://www.nytimes.com/2026/06/20/story.html"))
        // Trailing-dot already ran silently → never repeated as a pre-stage.
        XCTAssertFalse(stages.contains { $0.host?.hasSuffix(".") ?? false },
                       "trailing-dot must not be repeated as a WKWebView pre-stage")
        // No archive.today URL is ever a pre-stage.
        XCTAssertFalse(stages.contains { ArticleFetcher.isArchiveTodayURL($0) })
        // The third-party reader pages are the pre-stages.
        XCTAssertEqual(stages.first?.absoluteString.hasPrefix("https://smry.ai/"), true)
    }

    func testWSJHasNoTrailingDotButHasThirdPartyPages() {
        // WSJ's rule has no trailing-dot strategy → first pre-stage is a service page.
        let stages = ArchiveWebReaderViewController.webPreStageURLs(
            for: url("https://www.wsj.com/articles/x"))
        XCTAssertFalse(stages.contains { $0.host == "www.wsj.com." })
        XCTAssertTrue(stages.contains { $0.absoluteString.hasPrefix("https://removepaywalls.com/") })
        XCTAssertTrue(stages.contains { $0.absoluteString.hasPrefix("https://www.removepaywall.com/search?url=") })
    }

    func testArchiveTodayURLYieldsNoPreStages() {
        let stages = ArchiveWebReaderViewController.webPreStageURLs(
            for: url("https://archive.is/abcde"))
        XCTAssertTrue(stages.isEmpty)
    }

    func testNoSilentStrategyLeaksIntoPreStages() {
        // The generic (unknown-host) list contains many silent strategies; none of
        // them should appear as a pre-stage URL (only trailing-dot + third-party).
        let stages = ArchiveWebReaderViewController.webPreStageURLs(
            for: url("https://unknown.example/story"))
        for stage in stages {
            let isTrailingDot = stage.host?.hasSuffix(".") ?? false
            let isThirdParty = stage.host == "smry.ai" || stage.host == "removepaywalls.com"
                || stage.host == "www.removepaywall.com"
            XCTAssertTrue(isTrailingDot || isThirdParty, "unexpected pre-stage \(stage)")
        }
    }
}
