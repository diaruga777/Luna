//
//  FinishedReadingBadgeTests.swift
//  LunaTests
//

import XCTest
@testable import LunaReaderUI

@MainActor
final class FinishedReadingBadgeTests: XCTestCase {

    func testOlderDismissCompletionCannotHideNewPresentation() async {
        let badge = FinishedReadingBadgeView(frame: CGRect(x: 0, y: 0, width: 320, height: 92))
        badge.present()
        badge.dismissForTesting()
        badge.present()

        let animationSettled = expectation(description: "overlapping animations settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { animationSettled.fulfill() }
        await fulfillment(of: [animationSettled], timeout: 1)

        XCTAssertFalse(badge.isHidden)
        XCTAssertGreaterThan(badge.alpha, 0.9)
    }
}
