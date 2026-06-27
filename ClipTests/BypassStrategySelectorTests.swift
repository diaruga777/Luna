//
//  BypassStrategySelectorTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class BypassStrategySelectorTests: XCTestCase {
    private func url(_ string: String) -> URL { URL(string: string)! }
    private let firstParty: [BypassStrategy] = BypassStrategySelector.firstPartySilent
    private let locked = "<html><body>subscribe to continue reading</body></html>"

    func testNotPaywalledReturnsEmpty() {
        let html = "<html><body><article>" + String(repeating: "Free article. ", count: 100)
            + "</article></body></html>"
        // Regardless of the toggle, a non-paywall is never bypassed.
        for on in [true, false] {
            XCTAssertEqual(BypassStrategySelector.strategies(
                for: url("https://example.com/x"), directHTML: html, nonArchiveBypass: on), [])
        }
    }

    // MARK: - Toggle OFF (default) = long-standing archive-only behavior

    func testDefaultOffGoesStraightToArchive() {
        for article in ["https://www.wsj.com/articles/x", "https://unknown.example/story"] {
            XCTAssertEqual(
                BypassStrategySelector.strategies(for: url(article), directHTML: locked, nonArchiveBypass: false),
                [.archiveToday], article)
        }
        // NYT still gets only its trailing-dot pre-stage before archive.
        XCTAssertEqual(
            BypassStrategySelector.strategies(
                for: url("https://www.nytimes.com/story"), directHTML: locked, nonArchiveBypass: false),
            [.trailingDotHost, .archiveToday])
    }

    // MARK: - Toggle ON = first-party silent chain before archive

    func testOnRunsFirstPartySilentChainThenArchive() {
        for article in ["https://www.wsj.com/articles/x", "https://unknown.example/story"] {
            XCTAssertEqual(
                BypassStrategySelector.strategies(for: url(article), directHTML: locked, nonArchiveBypass: true),
                firstParty + [.archiveToday], article)
        }
    }

    func testOnTriesGooglebotBeforeArchiveForWSJ() {
        let strategies = BypassStrategySelector.strategies(
            for: url("https://www.wsj.com/articles/x"), directHTML: locked, nonArchiveBypass: true)
        let gbIndex = strategies.firstIndex(of: .userAgent(.googlebotDesktop))
        let archiveIndex = strategies.firstIndex(of: .archiveToday)
        XCTAssertNotNil(gbIndex)
        XCTAssertNotNil(archiveIndex)
        XCTAssertLessThan(gbIndex!, archiveIndex!)
    }

    func testOnNYTAlsoTriesTrailingDotBeforeArchive() {
        XCTAssertEqual(
            BypassStrategySelector.strategies(
                for: url("https://www.nytimes.com/story"), directHTML: locked, nonArchiveBypass: true),
            firstParty + [.trailingDotHost, .archiveToday])
    }
}
