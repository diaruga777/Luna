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

    private let firstParty: [BypassStrategy] = BypassStrategySelector.firstPartySilent

    func testPaywalledHostRunsFirstPartySilentChainThenArchive() {
        let locked = "<html><body>subscribe to continue reading</body></html>"
        // WSJ (and any non-NYT hard paywall): first-party silent reads, then archive.
        for article in ["https://www.wsj.com/articles/x", "https://unknown.example/story"] {
            XCTAssertEqual(BypassStrategySelector.strategies(for: url(article), directHTML: locked),
                           firstParty + [.archiveToday], article)
        }
    }

    func testGooglebotIsTriedBeforeArchiveForWSJ() {
        // The crux WSJ fix: a Googlebot read happens before the (failing) archiver.
        let locked = "<html><body>subscribe to continue reading</body></html>"
        let strategies = BypassStrategySelector.strategies(
            for: url("https://www.wsj.com/articles/x"), directHTML: locked)
        let gbIndex = strategies.firstIndex(of: .userAgent(.googlebotDesktop))
        let archiveIndex = strategies.firstIndex(of: .archiveToday)
        XCTAssertNotNil(gbIndex)
        XCTAssertNotNil(archiveIndex)
        XCTAssertLessThan(gbIndex!, archiveIndex!)
    }

    func testNYTAlsoTriesTrailingDotBeforeArchive() {
        let locked = "<html><body>subscribe to continue reading</body></html>"
        XCTAssertEqual(
            BypassStrategySelector.strategies(
                for: url("https://www.nytimes.com/story"), directHTML: locked),
            firstParty + [.trailingDotHost, .archiveToday])
    }
}
