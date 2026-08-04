//
//  ArchiveTrayPullPolicyTests.swift
//  LunaTests
//

import UIKit
import XCTest
@testable import Luna

final class ArchiveTrayPullPolicyTests: XCTestCase {

    private func shouldBegin(
        progress: CGFloat = 0,
        chromeHidden: Bool = false,
        hasContent: Bool = true,
        canPull: Bool = true,
        cardClaimsDrag: Bool = false,
        velocity: CGPoint
    ) -> Bool {
        ArchiveTrayPullPolicy.shouldBeginPull(
            progress: progress, chromeHidden: chromeHidden, hasContent: hasContent,
            canPull: canPull, cardClaimsDrag: cardClaimsDrag, velocity: velocity)
    }

    func testTheArcOpensOnlyOnALeftwardDrag() {
        XCTAssertTrue(shouldBegin(velocity: CGPoint(x: -400, y: 20)))
        XCTAssertFalse(shouldBegin(velocity: CGPoint(x: 400, y: 20)))
    }

    func testVerticalDragNeverPulls() {
        XCTAssertFalse(shouldBegin(velocity: CGPoint(x: -40, y: 400)))
    }

    /// The bug this policy was extracted for: on the last card the arc used to
    /// open on the very drag a video card was scrubbing with, so one gesture
    /// both seeked the timeline AND pulled the drawer in.
    func testAVideoCardsScrubIsNeverAlsoAPull() {
        XCTAssertFalse(shouldBegin(
            cardClaimsDrag: true, velocity: CGPoint(x: -400, y: 20)))
    }

    /// …but an arc already out stays interactive: the same drag has to be able
    /// to push it back, whatever is centered behind it.
    func testAnOpenArcStaysInteractiveOverScrubbableContent() {
        XCTAssertTrue(shouldBegin(
            progress: 1, cardClaimsDrag: true, velocity: CGPoint(x: 400, y: 20)))
    }

    func testHiddenChromeAndEmptyOrUnavailableArcsDoNotPull() {
        XCTAssertFalse(shouldBegin(chromeHidden: true, velocity: CGPoint(x: -400, y: 20)))
        XCTAssertFalse(shouldBegin(hasContent: false, velocity: CGPoint(x: -400, y: 20)))
        XCTAssertFalse(shouldBegin(canPull: false, velocity: CGPoint(x: -400, y: 20)))
    }
}
