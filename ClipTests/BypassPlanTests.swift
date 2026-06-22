//
//  BypassPlanTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class BypassPlanTests: XCTestCase {
    func testDetectedPaywallHasNoSilentOrPreStageFallbacks() {
        let url = URL(string: "https://www.wsj.com/articles/x")!
        let plan = BypassPlan.make(for: url, directHTML: "<html>subscribe to continue</html>")
        XCTAssertTrue(plan.silent.isEmpty)
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
}
