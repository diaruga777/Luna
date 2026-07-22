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
}
