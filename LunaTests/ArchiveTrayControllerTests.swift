//
//  ArchiveTrayControllerTests.swift
//  LunaTests
//

import UIKit
import XCTest
@testable import Luna

final class ArchiveTrayControllerTests: XCTestCase {

    /// Stands in for the deck the arc mounts in. Answers the tray's two
    /// questions and records the open states it reports.
    private final class TrayHost: ArchiveTrayDelegate {
        var shiftedViews: [UIView] = []
        var canPull = false
        var openStates: [Bool] = []

        func archiveTrayShiftedViews(_ tray: ArchiveTrayController) -> [UIView] { shiftedViews }
        func archiveTrayCanPull(_ tray: ArchiveTrayController) -> Bool { canPull }
        func archiveTray(_ tray: ArchiveTrayController, openStateDidChange open: Bool) {
            openStates.append(open)
        }
    }

    private func makeItem(title: String? = "Archived item", delete: (() -> Void)? = nil) -> ArchiveTrayItem {
        ArchiveTrayItem(
            id: UUID(), title: title, footer: nil, showsMetadata: title != nil,
            isAvailable: title != nil, loadImage: { $0(nil) }, tap: {}, share: { _ in },
            unarchive: { _ in }, delete: delete)
    }

    @MainActor
    func testArcIsOffscreenUntilRightmostCardBecomesAvailable() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let deck = TrayHost()
        let tray = ArchiveTrayController(host: host, delegate: deck)
        tray.setItems([makeItem()])

        tray.layout(in: host.view.bounds, safeAreaInsets: .zero)
        XCTAssertFalse(tray.isPullAvailableForTesting)
        XCTAssertEqual(tray.trayFrameForTesting.minX, 390, accuracy: 0.5)

        deck.canPull = true
        tray.refreshPullAvailability(animated: false)

        XCTAssertTrue(tray.isPullAvailableForTesting)
        XCTAssertEqual(tray.trayFrameForTesting.minX, 364, accuracy: 0.5)

        deck.canPull = false
        tray.refreshPullAvailability(animated: false)

        XCTAssertFalse(tray.isPullAvailableForTesting)
        XCTAssertEqual(tray.trayFrameForTesting.minX, 390, accuracy: 0.5)
    }

    @MainActor
    func testClosedArcPeeksOnlyWhenArchiveHasItems() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let deck = TrayHost()
        deck.canPull = true
        let tray = ArchiveTrayController(host: host, delegate: deck)

        // Available but empty: with no cells to peek (and no pull tab any
        // more), the closed arc stays fully offscreen.
        tray.layout(in: host.view.bounds, safeAreaInsets: .zero)
        XCTAssertTrue(tray.isPullAvailableForTesting)
        XCTAssertEqual(tray.trayFrameForTesting.minX, 390, accuracy: 0.5)

        tray.setItems([makeItem()])
        XCTAssertEqual(tray.trayFrameForTesting.minX, 364, accuracy: 0.5)

        tray.setItems([])
        XCTAssertEqual(tray.trayFrameForTesting.minX, 390, accuracy: 0.5)
    }

    @MainActor
    func testCellContextMenuOffersUnarchiveAndShare() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        let deck = TrayHost()
        deck.canPull = true
        let tray = ArchiveTrayController(host: host, delegate: deck)
        tray.setItems([makeItem()])

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
        let deck = TrayHost()
        deck.canPull = true
        let tray = ArchiveTrayController(host: host, delegate: deck)
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
        let deck = TrayHost()
        deck.canPull = true
        let tray = ArchiveTrayController(host: host, delegate: deck)
        tray.setItems([makeItem(title: nil, delete: { didDelete = true })])

        let menu = tray.contextMenuForTesting(itemAt: 0)
        let actions = menu.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(actions.map(\.title), ["Unarchive", "Share", "Delete"])
        let delete = try XCTUnwrap(actions.last)
        XCTAssertTrue(delete.attributes.contains(.destructive))

        delete.performWithSender(nil, target: nil)
        XCTAssertTrue(didDelete)
    }

    @MainActor
    func testNavigationTargetRetractsArcBeforeCurrentIndexChanges() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let deck = TrayHost()
        deck.canPull = true
        let tray = ArchiveTrayController(host: host, delegate: deck)
        tray.setItems([makeItem()])
        tray.layout(in: host.view.bounds, safeAreaInsets: .zero)

        XCTAssertTrue(tray.isPullAvailableForTesting)
        tray.setPullAvailable(false, animated: false)

        XCTAssertTrue(deck.canPull, "The carousel has not swapped its current index yet")
        XCTAssertFalse(tray.isPullAvailableForTesting)
        XCTAssertEqual(tray.trayFrameForTesting.minX, 390, accuracy: 0.5)

        // A cancelled swipe reports the still-current last card and restores
        // the peek even though `canPull` never changed in between.
        tray.setPullAvailable(true, animated: false)
        XCTAssertTrue(tray.isPullAvailableForTesting)
        XCTAssertEqual(tray.trayFrameForTesting.minX, 364, accuracy: 0.5)
    }

    @MainActor
    func testArcUsesNarrowCellsAndHeaderTitle() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let deck = TrayHost()
        deck.canPull = true
        let tray = ArchiveTrayController(host: host, delegate: deck)

        tray.layout(in: host.view.bounds, safeAreaInsets: .zero)

        // Narrower than the drawer (2/3 × 390 = 260) so off-apex cells have
        // room to drift rightward along the arc.
        XCTAssertEqual(tray.itemSizeForTesting.width, 204, accuracy: 0.5)
        XCTAssertEqual(tray.itemSizeForTesting.height, 128, accuracy: 0.5)
        XCTAssertEqual(tray.headerTitleForTesting, "archive")
    }

    @MainActor
    func testAudioChromeIsOccludedOnlyWhileTrayIsOpen() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let deck = TrayHost()
        deck.canPull = true
        let tray = ArchiveTrayController(host: host, delegate: deck)

        tray.layout(in: host.view.bounds, safeAreaInsets: .zero)
        XCTAssertEqual(deck.openStates.last, false)

        // Pulling even partially open immediately removes controls that would
        // otherwise remain visible over the revealed arc.
        tray.setOpenForTesting(true)
        XCTAssertEqual(deck.openStates.last, true)
        tray.setOpenForTesting(false)
        XCTAssertEqual(deck.openStates.last, false)
    }

    @MainActor
    func testChromeHiddenFadesTheClosedArcAndRestores() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let deck = TrayHost()
        deck.canPull = true
        let tray = ArchiveTrayController(host: host, delegate: deck)
        tray.setItems([makeItem()])
        tray.layout(in: host.view.bounds, safeAreaInsets: .zero)
        XCTAssertEqual(tray.trayAlphaForTesting, 1, accuracy: 0.001)

        tray.setChromeHidden(true, animated: false)
        XCTAssertEqual(tray.trayAlphaForTesting, 0, accuracy: 0.001)

        tray.setChromeHidden(false, animated: false)
        XCTAssertEqual(tray.trayAlphaForTesting, 1, accuracy: 0.001)
    }

    @MainActor
    func testChromeHiddenClosesAnOpenArcBeforeFading() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let shifted = UIView()
        let deck = TrayHost()
        deck.canPull = true
        deck.shiftedViews = [shifted]
        let tray = ArchiveTrayController(host: host, delegate: deck)
        tray.setItems([makeItem()])
        tray.layout(in: host.view.bounds, safeAreaInsets: .zero)
        tray.setOpenForTesting(true)

        tray.setChromeHidden(true, animated: false)

        // The shifted card must never be left stranded behind an invisible
        // drawer: hiding closes the arc and undoes the 2/3 shift.
        XCTAssertEqual(tray.trayAlphaForTesting, 0, accuracy: 0.001)
        XCTAssertEqual(shifted.transform.tx, 0, accuracy: 0.5)
        XCTAssertEqual(tray.trayFrameForTesting.minX, 364, accuracy: 0.5)
    }

    /// Downloader re-downloads an unavailable archived item in place, so its
    /// progress bar belongs on that item's own cell.
    @MainActor
    func testArchivedItemDrawsItsOwnDownloadProgressBar() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let deck = TrayHost()
        deck.canPull = true
        let tray = ArchiveTrayController(host: host, delegate: deck)
        let unavailable = makeItem(title: nil)
        tray.setItems([unavailable])
        tray.layout(in: host.view.bounds, safeAreaInsets: .zero)

        // No job: no bar.
        XCTAssertNil(tray.cellDownloadProgressForTesting(itemAt: 0))

        tray.setDownloadProgress([unavailable.id: 0.42])
        XCTAssertEqual(try XCTUnwrap(tray.cellDownloadProgressForTesting(itemAt: 0)), 0.42, accuracy: 0.001)

        // Another item's job leaves this cell alone.
        tray.setDownloadProgress([UUID(): 0.9])
        XCTAssertNil(tray.cellDownloadProgressForTesting(itemAt: 0))
    }

    /// Progress ticks arrive several times a second; reloading the arc for each
    /// one would restart every visible cell's thumbnail load.
    @MainActor
    func testProgressUpdatesReuseTheSameCellInsteadOfReloading() throws {
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let deck = TrayHost()
        deck.canPull = true
        let tray = ArchiveTrayController(host: host, delegate: deck)
        let item = makeItem(title: nil)
        tray.setItems([item])
        tray.layout(in: host.view.bounds, safeAreaInsets: .zero)
        let cell = try XCTUnwrap(tray.cellForTesting(itemAt: 0))

        tray.setDownloadProgress([item.id: 0.1])
        tray.setDownloadProgress([item.id: 0.75])

        XCTAssertIdentical(tray.cellForTesting(itemAt: 0), cell)
        XCTAssertEqual(try XCTUnwrap(tray.cellDownloadProgressForTesting(itemAt: 0)), 0.75, accuracy: 0.001)
    }

    @MainActor
    func testOpeningShiftsTheCardByTwoThirdsOfTheScreen() {
        let host = UIViewController()
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        let shifted = UIView()
        let deck = TrayHost()
        deck.canPull = true
        deck.shiftedViews = [shifted]
        let tray = ArchiveTrayController(host: host, delegate: deck)
        tray.layout(in: host.view.bounds, safeAreaInsets: .zero)

        tray.setOpenForTesting(true)
        XCTAssertEqual(shifted.transform.tx, -260, accuracy: 0.5)
        XCTAssertEqual(tray.trayFrameForTesting.minX, 130, accuracy: 0.5)

        tray.setOpenForTesting(false)
        XCTAssertEqual(shifted.transform.tx, 0, accuracy: 0.5)
    }
}

final class ArchiveArcLayoutTests: XCTestCase {

    /// Plain data source so the layout can be exercised without the tray.
    private final class StubDataSource: NSObject, UICollectionViewDataSource {
        let count: Int
        init(count: Int) { self.count = count }
        func collectionView(
            _ collectionView: UICollectionView, numberOfItemsInSection section: Int
        ) -> Int { count }
        func collectionView(
            _ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath
        ) -> UICollectionViewCell {
            collectionView.dequeueReusableCell(withReuseIdentifier: "cell", for: indexPath)
        }
    }

    /// Retains the collection view and data source (the layout only holds
    /// them weakly) for as long as a test computes attributes.
    private final class ArcFixture {
        let collection: UICollectionView
        let layout: ArchiveArcLayout
        private let dataSource: StubDataSource

        @MainActor
        init(count: Int, height: CGFloat = 800) {
            layout = ArchiveArcLayout()
            layout.itemSize = CGSize(width: 200, height: 128)
            layout.radius = 900
            collection = UICollectionView(
                frame: CGRect(x: 0, y: 0, width: 260, height: height),
                collectionViewLayout: layout)
            collection.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "cell")
            dataSource = StubDataSource(count: count)
            collection.dataSource = dataSource
            collection.reloadData()
            collection.layoutIfNeeded()
        }

        @MainActor
        func attributes(at item: Int) throws -> UICollectionViewLayoutAttributes {
            try XCTUnwrap(layout.layoutAttributesForItem(at: IndexPath(item: item, section: 0)))
        }
    }

    private func rotation(of attributes: UICollectionViewLayoutAttributes) -> CGFloat {
        atan2(attributes.transform.b, attributes.transform.a)
    }

    @MainActor
    func testCellsBowLeftAndTiltAwayFromTheViewportMidline() throws {
        let fixture = ArcFixture(count: 8)
        let attributes = try (0..<8).map { try fixture.attributes(at: $0) }

        // The item nearest the viewport midline is the arc's apex: leftmost,
        // and essentially untilted.
        let apex = try XCTUnwrap(
            attributes.min { abs(rotation(of: $0)) < abs(rotation(of: $1)) })
        XCTAssertLessThan(abs(rotation(of: apex)), 0.02)
        for other in attributes where other !== apex {
            XCTAssertGreaterThanOrEqual(other.center.x, apex.center.x - 0.5)
        }

        // Items above the midline tilt one way, items below the other, and
        // the tilt grows with distance.
        let first = try XCTUnwrap(attributes.first)
        let last = try XCTUnwrap(attributes.last)
        XCTAssertGreaterThan(rotation(of: first), 0.02)
        XCTAssertLessThan(rotation(of: last), -0.02)
        XCTAssertGreaterThan(abs(rotation(of: first)), abs(rotation(of: attributes[2])))
    }

    @MainActor
    func testScrollingRotatesTheArc() throws {
        let fixture = ArcFixture(count: 12)
        let rotationBefore = rotation(of: try fixture.attributes(at: 6))

        fixture.collection.contentOffset = CGPoint(x: 0, y: 200)
        fixture.collection.layoutIfNeeded()

        // Scrolling down carries the item up the arc: its tilt keeps
        // increasing toward the apex rather than translating rigidly.
        XCTAssertGreaterThan(rotation(of: try fixture.attributes(at: 6)), rotationBefore + 0.1)
    }

    @MainActor
    func testShortContentCentersOnTheApex() throws {
        let fixture = ArcFixture(count: 2)
        let cell = try fixture.attributes(at: 1)
        // Header + one cell pinned to the top would ride the arc's upper
        // sweep, drifting right off the screen edge; centered, the lone cell
        // sits near the apex — essentially untilted and leftmost.
        XCTAssertEqual(cell.center.y, 400, accuracy: 30)
        XCTAssertLessThan(abs(rotation(of: cell)), 0.05)
    }

    @MainActor
    func testFirstItemUsesTheHeaderHeight() throws {
        let fixture = ArcFixture(count: 3)
        let header = try fixture.attributes(at: 0)
        let cell = try fixture.attributes(at: 1)
        XCTAssertEqual(header.size.height, fixture.layout.headerHeight, accuracy: 0.5)
        XCTAssertEqual(cell.size.height, 128, accuracy: 0.5)
        XCTAssertEqual(header.size.width, cell.size.width, accuracy: 0.5)
    }
}
