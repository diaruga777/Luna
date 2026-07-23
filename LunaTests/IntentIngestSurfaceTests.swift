//
//  IntentIngestSurfaceTests.swift
//  LunaTests
//

import LunaModels
import LunaReadingList
import XCTest
@testable import LunaIntents

final class IntentIngestSurfaceTests: XCTestCase {

    func testUnsupportedKindResultSurvivesIntentOutcomeMapping() {
        let mapped = IntentIngestHelper.actionButtonOutcome(
            from: .unsupportedKind(owner: .downloader))

        guard case let .unsupportedKind(owner) = mapped else {
            return XCTFail("expected unsupportedKind result, got \(mapped)")
        }
        XCTAssertEqual(owner, .downloader)
    }

    func testTimeoutStillMapsToIndeterminateCompletion() {
        let mapped = IntentIngestHelper.actionButtonOutcome(from: nil)

        guard case let .completed(savedURLString) = mapped else {
            return XCTFail("expected completion, got \(mapped)")
        }
        XCTAssertNil(savedURLString)
    }

    func testIgnoredMapsToCompletedWithTheIgnoredURL() {
        let mapped = IntentIngestHelper.actionButtonOutcome(
            from: .ignored, ignoredURLString: "https://example.com/already-saved")

        guard case let .completed(savedURLString) = mapped else {
            return XCTFail("expected completion, got \(mapped)")
        }
        XCTAssertEqual(savedURLString, "https://example.com/already-saved")
    }
}
