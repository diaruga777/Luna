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
    func testCellContextMenuOffersUnarchiveAndShare() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        let tray = ArchiveTrayController(
            host: host, shiftedViews: { [] }, canPull: { true })
        tray.setItems([ArchiveTrayItem(
            id: UUID(), title: "Archived item", footer: nil, showsMetadata: true,
            isAvailable: true, loadImage: { $0(nil) }, tap: {}, share: { _ in },
            unarchive: { _ in }, delete: nil)])

        let titles = tray.contextMenuForTesting(itemAt: 0).children.compactMap {
            ($0 as? UIAction)?.title
        }
        XCTAssertEqual(titles, ["Unarchive", "Share"])
    }

    @MainActor
    func testUnarchiveActionReceivesItsSourceView() throws {
        let host = UIViewController()
        host.loadViewIfNeeded()
        var receivedSource: UIView?
        let tray = ArchiveTrayController(
            host: host, shiftedViews: { [] }, canPull: { true })
        tray.setItems([ArchiveTrayItem(
            id: UUID(), title: "Archived item", footer: nil, showsMetadata: true,
            isAvailable: true, loadImage: { $0(nil) }, tap: {}, share: { _ in },
            unarchive: { receivedSource = $0 }, delete: nil)])

        let action = try XCTUnwrap(
            tray.contextMenuForTesting(itemAt: 0).children.first as? UIAction)
        action.performWithSender(nil, target: nil)

        XCTAssertNotNil(receivedSource)
    }

    @MainActor
    func testCellContextMenuOffersDestructiveDeleteWhenSurfaceProvidesIt() throws {
        let host = UIViewController()
        host.loadViewIfNeeded()
        var didDelete = false
        let tray = ArchiveTrayController(
            host: host, shiftedViews: { [] }, canPull: { true })
        tray.setItems([ArchiveTrayItem(
            id: UUID(), title: nil, footer: nil, showsMetadata: false,
            isAvailable: false, loadImage: { $0(nil) }, tap: {}, share: { _ in },
            unarchive: { _ in }, delete: { didDelete = true })])

        let menu = tray.contextMenuForTesting(itemAt: 0)
        let actions = menu.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(actions.map(\.title), ["Unarchive", "Share", "Delete"])
        let delete = try XCTUnwrap(actions.last)
        XCTAssertTrue(delete.attributes.contains(.destructive))

        delete.performWithSender(nil, target: nil)
        XCTAssertTrue(didDelete)
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

    @MainActor
    func testTrayUsesOpaqueNeutralStylingAndSingleColumnRectangles() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let tray = ArchiveTrayController(
            host: host, shiftedViews: { [] }, canPull: { true })

        tray.layout(in: host.view.bounds, safeAreaInsets: .zero)

        let resolvedBackground = tray.trayBackgroundColorForTesting?.resolvedColor(
            with: host.traitCollection)
        XCTAssertNotNil(resolvedBackground)
        XCTAssertEqual(resolvedBackground?.cgColor.alpha ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(tray.itemSizeForTesting.width, 232, accuracy: 0.5)
        XCTAssertEqual(tray.itemSizeForTesting.height, 128, accuracy: 0.5)
        XCTAssertEqual(tray.archiveLabelTextForTesting, "archive")
        XCTAssertEqual(tray.archiveLabelNumberOfLinesForTesting, 1)
    }

    @MainActor
    func testAudioChromeIsOccludedOnlyWhileTrayIsOpen() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        var openStates: [Bool] = []
        let tray = ArchiveTrayController(
            host: host,
            shiftedViews: { [] },
            canPull: { true },
            openStateChanged: { openStates.append($0) })

        tray.layout(in: host.view.bounds, safeAreaInsets: .zero)
        XCTAssertEqual(openStates.last, false)

        // Pulling even partially open immediately removes controls that would
        // otherwise remain visible through the tray's rounded corner.
        tray.setOpenForTesting(true)
        XCTAssertEqual(openStates.last, true)
        tray.setOpenForTesting(false)
        XCTAssertEqual(openStates.last, false)
    }
}
