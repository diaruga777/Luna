//
//  BypassStrategySelectorTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class BypassStrategySelectorTests: XCTestCase {
    private func url(_ string: String) -> URL { URL(string: string)! }

    func testNotPaywalledReturnsEmpty() {
        let html = "<html><body><article>" + String(repeating: "Free article. ", count: 100)
            + "</article></body></html>"
        XCTAssertEqual(BypassStrategySelector.strategies(for: url("https://example.com/x"), directHTML: html), [])
    }

    func testNYTTriesTrailingDotBeforeArchiveIs() {
        let locked = "<html><body>subscribe to continue reading</body></html>"
        XCTAssertEqual(
            BypassStrategySelector.strategies(
                for: url("https://www.nytimes.com/story"), directHTML: locked),
            [.trailingDotHost, .archiveToday])
        for article in ["https://www.wsj.com/articles/x", "https://unknown.example/story"] {
            XCTAssertEqual(BypassStrategySelector.strategies(for: url(article), directHTML: locked),
                           [.archiveToday], article)
        }
    }
}
