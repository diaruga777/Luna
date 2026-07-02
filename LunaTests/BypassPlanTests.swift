//
//  BypassPlanTests.swift
//  LunaTests
//

import LunaPaywallBypass
import XCTest
@testable import Luna

final class BypassPlanTests: XCTestCase {
    func testWSJDefaultOffGoesStraightToArchive() {
        let url = URL(string: "https://www.wsj.com/articles/x")!
        // Default (toggle off): no silent reads, no pre-stages — archive only.
        let plan = BypassPlan.make(
            for: url, directHTML: "<html>subscribe to continue</html>", nonArchiveBypass: false)
        XCTAssertTrue(plan.silent.isEmpty)
        XCTAssertTrue(plan.webPreStages.isEmpty)
        XCTAssertTrue(plan.allowsArchiveToday)
    }

    func testWSJWithToggleOnRoutesToBrowserDirectUnlockThenArchive() {
        let url = URL(string: "https://www.wsj.com/articles/x")!
        let plan = BypassPlan.make(
            for: url, directHTML: "<html>subscribe to continue</html>", nonArchiveBypass: true)
        // The rule-driven silent request leg is run by the resolver (not emitted as a
        // strategy), so the plan carries no silent strategies — only the browser-tier
        // direct unlock before parking for archive.today.
        XCTAssertTrue(plan.silent.isEmpty)
        XCTAssertEqual(plan.webPreStages, [.directUnlock])
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
