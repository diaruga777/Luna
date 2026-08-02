//
//  LeftTrayControllerStateTests.swift
//  LunaTests
//

import XCTest
@testable import Luna

@MainActor
final class LeftTrayControllerStateTests: XCTestCase {
    func testRefreshReassertsPeekWhenFirstCardAvailabilityDidNotChange() throws {
        let host = CardCarouselHostViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.mountLeftTray(
            shifting: { [] }, canPull: { true },
            savedURL: { _, _, _ in })
        host.viewDidLayoutSubviews()

        let tray = try XCTUnwrap(host.leftTray)
        XCTAssertEqual(tray.trayFrameForTesting.maxX, 26, accuracy: 0.5)

        // Models the stale closed position left behind when card zero is
        // deleted and its right-hand successor is synchronously reloaded at
        // index zero. Availability is true both before and after the reload.
        tray.offsetTrayForTesting(by: -26)
        XCTAssertEqual(tray.trayFrameForTesting.maxX, 0, accuracy: 0.5)

        host.refreshLeftPullAvailability(animated: false)

        XCTAssertEqual(
            tray.trayFrameForTesting.maxX, 26, accuracy: 0.5,
            "Refreshing the same true state must restore the left-tray peek")
    }

    func testPasteboardMovesToTrailingEdgeOnlyWhileTrayIsCollapsed() throws {
        let host = CardCarouselHostViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.mountLeftTray(
            shifting: { [] }, canPull: { true },
            savedURL: { _, _, _ in })
        host.viewDidLayoutSubviews()

        let tray = try XCTUnwrap(host.leftTray)
        tray.setOpenForTesting(true)
        host.view.layoutIfNeeded()
        let openFrame = try XCTUnwrap(tray.pasteboardFrameInTrayForTesting)

        tray.setOpenForTesting(false)
        host.view.layoutIfNeeded()
        let closedFrame = try XCTUnwrap(tray.pasteboardFrameInTrayForTesting)

        XCTAssertGreaterThan(
            closedFrame.minX, openFrame.minX + 50,
            "The clipboard should travel right within the retracting tray")
        XCTAssertEqual(
            closedFrame.midX, tray.trayFrameForTesting.width - 8, accuracy: 1,
            "The clipboard's recognizable center clip should occupy the peek")
        XCTAssertEqual(tray.trayFrameForTesting.maxX, 26, accuracy: 0.5)
    }
}
