//
//  ArchiveTrayControllerTests.swift
//  LunaTests
//

import UIKit
import XCTest
@testable import Luna

final class ArchiveTrayControllerTests: XCTestCase {

    @MainActor
    func testPullTabIsOffscreenUntilRightmostCardBecomesAvailable() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        var isRightmost = false
        let tray = ArchiveTrayController(
            host: host, shiftedViews: { [] }, canPull: { isRightmost })

        tray.layout(in: host.view.bounds, safeAreaInsets: .zero)
        XCTAssertFalse(tray.isPullAvailableForTesting)
        XCTAssertEqual(tray.trayFrameForTesting.minX, 420, accuracy: 0.5)

        isRightmost = true
        tray.refreshPullAvailability(animated: false)

        XCTAssertTrue(tray.isPullAvailableForTesting)
        XCTAssertEqual(tray.trayFrameForTesting.minX, 377, accuracy: 0.5)

        isRightmost = false
        tray.refreshPullAvailability(animated: false)

        XCTAssertFalse(tray.isPullAvailableForTesting)
        XCTAssertEqual(tray.trayFrameForTesting.minX, 420, accuracy: 0.5)
    }

    @MainActor
    func testLongPressCancelsTheCellTapItReplaces() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        let tray = ArchiveTrayController(
            host: host, shiftedViews: { [] }, canPull: { true })

        XCTAssertTrue(tray.unarchivePressCancelsTouchesForTesting)
    }

    @MainActor
    func testNavigationTargetRetractsTabBeforeCurrentIndexChanges() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let isRightmost = true
        let tray = ArchiveTrayController(
            host: host, shiftedViews: { [] }, canPull: { isRightmost })
        tray.layout(in: host.view.bounds, safeAreaInsets: .zero)

        XCTAssertTrue(tray.isPullAvailableForTesting)
        tray.setPullAvailable(false, animated: false)

        XCTAssertTrue(isRightmost, "The carousel has not swapped its current index yet")
        XCTAssertFalse(tray.isPullAvailableForTesting)
        XCTAssertEqual(tray.trayFrameForTesting.minX, 420, accuracy: 0.5)

        // A cancelled swipe reports the still-current last card and restores
        // the pull tab even though `canPull` never changed in between.
        tray.setPullAvailable(true, animated: false)
        XCTAssertTrue(tray.isPullAvailableForTesting)
        XCTAssertEqual(tray.trayFrameForTesting.minX, 377, accuracy: 0.5)
    }
}
