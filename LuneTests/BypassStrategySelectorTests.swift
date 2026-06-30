//
//  BypassStrategySelectorTests.swift
//  LuneTests
//

import LunePaywallBypass
import XCTest
@testable import Lune

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

    func testOnRunsFirstPartySilentChainThenDirectUnlockThenArchive() {
        for article in ["https://www.wsj.com/articles/x", "https://unknown.example/story"] {
            XCTAssertEqual(
                BypassStrategySelector.strategies(for: url(article), directHTML: locked, nonArchiveBypass: true),
                firstParty + [.directUnlock, .archiveToday], article)
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
            firstParty + [.directUnlock, .trailingDotHost, .archiveToday])
    }

    /// Toggle ON: a BPC-known paywall host with NO generic paywall evidence (a page
    /// that fetched fine but shows no markers) is still routed through the unlock
    /// flow. Toggle OFF: the same page is left alone (no regression).
    func testOnKnownPaywallHostWithoutMarkersStillBypasses() {
        // delish.com is in the BPC list but NOT our hard-paywall list, so a no-marker
        // page yields a `.notPaywalled` gate decision — the exact case the toggle-on
        // override flips (a hard-paywall host would bypass regardless of the toggle).
        let noEvidence = "<html><body><p>" + String(repeating: "short. ", count: 5) + "</p></body></html>"
        let known = url("https://www.delish.com/story")
        XCTAssertEqual(
            BypassStrategySelector.strategies(for: known, directHTML: noEvidence, nonArchiveBypass: true),
            firstParty + [.directUnlock, .archiveToday])
        XCTAssertEqual(
            BypassStrategySelector.strategies(for: known, directHTML: noEvidence, nonArchiveBypass: false),
            [])
    }

    /// Even toggle ON must never bypass a non-paywall unknown host with no evidence.
    func testOnUnknownHostWithoutMarkersIsNotBypassed() {
        let noEvidence = "<html><body><p>" + String(repeating: "short. ", count: 5) + "</p></body></html>"
        XCTAssertEqual(
            BypassStrategySelector.strategies(
                for: url("https://randomblog.example/post"), directHTML: noEvidence, nonArchiveBypass: true),
            [])
    }
}
