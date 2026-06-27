//
//  BypassPlanTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class BypassPlanTests: XCTestCase {
    func testWSJRunsFirstPartySilentChainThenArchive() {
        let url = URL(string: "https://www.wsj.com/articles/x")!
        let plan = BypassPlan.make(for: url, directHTML: "<html>subscribe to continue</html>")
        // The first-party silent reads run before parking for archive.today; WSJ is
        // not an NYT-family host, so there's no trailing-dot web pre-stage.
        XCTAssertEqual(plan.silent, [
            .jsonLDBody, .userAgent(.googlebotDesktop), .userAgent(.googlebotMobile),
            .freshSession, .amp, .waybackRaw,
        ])
        XCTAssertTrue(plan.webPreStages.isEmpty)
        XCTAssertTrue(plan.allowsArchiveToday)
    }

    func testNonPaywalledHostHasNoArchivePlan() {
        let url = URL(string: "https://example.com/story")!
        let html = "<article>" + String(repeating: "Free article. ", count: 100) + "</article>"
        let plan = BypassPlan.make(for: url, directHTML: html)
        XCTAssertTrue(plan.silent.isEmpty)
        XCTAssertTrue(plan.webPreStages.isEmpty)
        XCTAssertFalse(plan.allowsArchiveToday)
    }

    /// NYT's trailing-dot trick is a client-side origin behaviour, so it must be
    /// retried in the WKWebView (a real browser) before archive.today — even though
    /// the silent URLSession fetch already tried it and failed.
    func testNYTRetriesTrailingDotInWebViewBeforeArchive() {
        let url = URL(string: "https://www.nytimes.com/2026/06/26/world/americas/x.html")!
        let plan = BypassPlan.make(for: url, directHTML: "<html>subscribe to continue reading</html>")
        XCTAssertTrue(plan.silent.contains(.trailingDotHost))
        XCTAssertEqual(plan.webPreStages, [.trailingDotHost])
        XCTAssertTrue(plan.allowsArchiveToday)
    }
}
