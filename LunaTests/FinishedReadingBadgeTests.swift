//
//  FinishedReadingBadgeTests.swift
//  LunaTests
//

import XCTest
@testable import LunaReaderUI

@MainActor
final class FinishedReadingBadgeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        FinishedReadingBadgeView.resetExplanationForTesting()
    }

    func testPresentationDrawsCheckmarkBeforeLeavingReadPillVisible() {
        let badge = makeBadge()
        badge.present()

        XCTAssertFalse(badge.isHidden)
        XCTAssertTrue(badge.checkmarkIsDrawingForTesting)
        XCTAssertTrue(badge.readLabelIsStationaryForTesting)
        XCTAssertEqual(badge.accessibilityLabel, "Read")
    }

    func testExpandedArchiveStatusReturnsToPersistentReadPill() async {
        let badge = makeBadge()
        badge.present()
        badge.expandForTesting()

        XCTAssertTrue(badge.isExpandedForTesting)
        XCTAssertTrue(badge.checkmarkIsHiddenForTesting)
        XCTAssertEqual(badge.accessibilityLabel, "Sent to archive")

        badge.collapseForTesting()
        let animationSettled = expectation(description: "pill collapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { animationSettled.fulfill() }
        await fulfillment(of: [animationSettled], timeout: 1)

        XCTAssertFalse(badge.isHidden)
        XCTAssertFalse(badge.isExpandedForTesting)
        XCTAssertFalse(badge.checkmarkIsHiddenForTesting)
        XCTAssertEqual(badge.accessibilityLabel, "Read")
    }

    func testFirstPresentationExpandsArchiveStatusAfterBriefDelay() async {
        let badge = makeBadge()
        badge.present()

        let delayElapsed = expectation(description: "first-use expansion delay elapsed")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) { delayElapsed.fulfill() }
        await fulfillment(of: [delayElapsed], timeout: 2)

        XCTAssertTrue(badge.isExpandedForTesting)
        XCTAssertEqual(badge.accessibilityLabel, "Sent to archive")
    }

    private func makeBadge() -> FinishedReadingBadgeView {
        FinishedReadingBadgeView(
            frame: CGRect(x: 0, y: 0, width: 220, height: FinishedReadingBadgeView.pillHeight))
    }
}
