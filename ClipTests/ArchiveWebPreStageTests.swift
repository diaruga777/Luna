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

    func testNYTLeadsWithTrailingDotThenThirdPartyPages() {
        let stages = ArchiveWebReaderViewController.webPreStageURLs(
            for: url("https://www.nytimes.com/2026/06/20/story.html"))
        XCTAssertEqual(stages.first?.host, "www.nytimes.com.")
        // No archive.today URL is ever a pre-stage.
        XCTAssertFalse(stages.contains { ArticleFetcher.isArchiveTodayURL($0) })
        // The third-party reader pages follow.
        XCTAssertTrue(stages.contains { $0.absoluteString.hasPrefix("https://smry.ai/") })
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
