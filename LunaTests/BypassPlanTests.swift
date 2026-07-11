//
//  BypassPlanTests.swift
//  LunaTests
//

import LunaPaywallBypass
import XCTest
@testable import Luna

final class BypassPlanTests: XCTestCase {
    func testWSJUsesDirectUnlockThenArchive() {
        let url = URL(string: "https://www.wsj.com/articles/x")!
        let plan = BypassPlan.make(for: url, directHTML: "<html>subscribe to continue</html>")
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

    func testNYTUsesItsDirectUnlockRuleBeforeArchive() {
        let url = URL(string: "https://www.nytimes.com/2026/06/26/world/americas/x.html")!
        let plan = BypassPlan.make(for: url, directHTML: "<html>subscribe to continue reading</html>")
        XCTAssertFalse(plan.silent.contains(.trailingDotHost))
        XCTAssertEqual(plan.webPreStages, [.directUnlock])
        XCTAssertTrue(plan.allowsArchiveToday)
    }
}
