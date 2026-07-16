//
//  IntentIngestInteropTests.swift
//  LunaTests
//

import LunaInterop
import LunaReadingList
import XCTest
@testable import LunaIntents

final class IntentIngestInteropTests: XCTestCase {

    func testBlockedResultSurvivesIntentOutcomeMapping() {
        let mapped = IntentIngestHelper.actionButtonOutcome(
            from: .blockedByInterop(owner: .downloader, ownerInstalled: false))

        guard case let .blockedByInterop(owner, ownerInstalled) = mapped else {
            return XCTFail("expected blocked interop result, got \(mapped)")
        }
        XCTAssertEqual(owner, .downloader)
        XCTAssertFalse(ownerInstalled)
    }

    func testTimeoutStillMapsToIndeterminateCompletion() {
        let mapped = IntentIngestHelper.actionButtonOutcome(from: nil)

        guard case let .completed(savedURLString, needsInstallOwner) = mapped else {
            return XCTFail("expected completion, got \(mapped)")
        }
        XCTAssertNil(savedURLString)
        XCTAssertNil(needsInstallOwner)
    }
}
