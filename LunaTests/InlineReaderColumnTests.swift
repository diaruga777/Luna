//
//  InlineReaderColumnTests.swift
//  LunaTests
//
//  The iPad's nested reader: a second card BESIDE the one you were reading
//  rather than a tab over it. Covers the geometry (two identical columns), the
//  deck's step aside, the return to center, and the rule that a link from
//  either card stacks on the right one instead of opening a third.
//

import LunaDesignSystem
import LunaModels
import LunaReaderUI
import LunaStorage
import UIKit
import XCTest
@testable import Luna

@MainActor
final class InlineReaderColumnTests: XCTestCase {

    /// An iPad-portrait-sized deck, wide enough for two columns.
    private static let wideSize = CGSize(width: 1024, height: 1366)
    /// An iPhone-sized deck, which keeps the overlay behaviour.
    private static let narrowSize = CGSize(width: 402, height: 874)

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        ReadingListStore.shared.seedForTesting(items: [], contents: [:])
        super.tearDown()
    }

    // MARK: - Placement

    func testAWideDeckHasRoomForASecondColumnAndAPhoneSizedOneDoesNot() {
        XCTAssertTrue(makeController(size: Self.wideSize).hasRoomForColumn)
        XCTAssertFalse(makeController(size: Self.narrowSize).hasRoomForColumn)
    }

    func testAPhoneSizedDeckNeverInstallsAColumn() {
        let controller = makeController(size: Self.narrowSize)
        _ = withAnimationsDisabled {
            controller.openNestedReaderForTesting(
                url: URL(string: "https://example.com/linked")!,
                sourcePointInWindow: CGPoint(x: 200, y: 400))
        }
        XCTAssertNil(controller.openInlineColumn)
        XCTAssertEqual(controller.carousel.columnAsideShift, 0, accuracy: 0.01)
        // Whatever it did open, it was a presentation over this reader.
        XCTAssertTrue(
            controller.children.allSatisfy { !($0 is SplitWebOverlayViewController) })
    }

    // MARK: - Geometry

    /// The two cards are the same size by construction — the left one is not
    /// resized, it is moved — and together they span the container minus one
    /// edge padding on each side.
    func testTheColumnIsTheSameCardOneColumnToTheRight() throws {
        let controller = makeController(size: Self.wideSize)
        let restingBefore = try XCTUnwrap(
            controller.carousel.restingCenteredCardFrame(in: controller.view))

        let column = try XCTUnwrap(openColumn(on: controller))
        controller.view.layoutIfNeeded()

        let left = try XCTUnwrap(
            controller.carousel.restingCenteredCardFrame(in: controller.view))
        let right = column.view.frame

        XCTAssertEqual(right.size.width, left.size.width, accuracy: 0.5)
        XCTAssertEqual(right.size.height, left.size.height, accuracy: 0.5)
        XCTAssertEqual(right.minY, left.minY, accuracy: 0.5)
        XCTAssertEqual(
            right.minX - left.maxX, LunaLayout.columnGap, accuracy: 0.5,
            "the two columns should be exactly one gap apart")
        XCTAssertEqual(
            left.minX, LunaLayout.wideEdgePadding, accuracy: 0.5)
        XCTAssertEqual(
            Self.wideSize.width - right.maxX, LunaLayout.wideEdgePadding, accuracy: 0.5)

        // The left card MOVED; it kept its size.
        XCTAssertEqual(left.size.width, restingBefore.size.width, accuracy: 0.5)
        XCTAssertLessThan(left.minX, restingBefore.minX)
    }

    /// "Bringing back card chrome": a paired layout is the surfaced state, so
    /// reading the left card can no longer fade the deck away or grow the card
    /// down over the column's own controls.
    func testPairingSurfacesTheDeckAndThenRefusesToImmerseAgain() throws {
        let controller = makeController(size: Self.wideSize)
        withAnimationsDisabled {
            controller.carousel(
                controller.carousel, didTapCenteredCardAt: controller.carousel.currentIndex)
        }
        XCTAssertTrue(controller.carousel.isImmersed, "precondition: reading dismissed the chrome")

        let column = try XCTUnwrap(openColumn(on: controller))
        XCTAssertFalse(controller.carousel.isImmersed)
        XCTAssertNotNil(controller.openInlineColumn)

        withAnimationsDisabled {
            controller.carousel(
                controller.carousel, didTapCenteredCardAt: controller.carousel.currentIndex)
        }
        XCTAssertFalse(
            controller.carousel.isImmersed,
            "a tap on the left card must not immerse it while a column is open")
        XCTAssertNotNil(column.view.superview)
    }

    /// Paging would swap the card the column's own outer tab points at.
    func testPagingAndScrubbingAreOffWhileAColumnIsOpen() throws {
        let controller = makeController(size: Self.wideSize, itemCount: 3)
        let startIndex = controller.carousel.currentIndex
        _ = try XCTUnwrap(openColumn(on: controller))

        withAnimationsDisabled { controller.carousel.page(by: 1) }
        XCTAssertEqual(controller.carousel.currentIndex, startIndex)
    }

    // MARK: - Closing

    func testClosingTheColumnBringsTheLeftCardBackToCenter() throws {
        let controller = makeController(size: Self.wideSize)
        let column = try XCTUnwrap(openColumn(on: controller))
        XCTAssertLessThan(controller.carousel.columnAsideShift, 0)

        let removed = expectation(description: "column removed from its host")
        withAnimationsDisabled { controller.closeInlineColumn(column) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { removed.fulfill() }
        wait(for: [removed], timeout: 3)

        XCTAssertEqual(controller.carousel.columnAsideShift, 0, accuracy: 0.01)
        XCTAssertNil(controller.openInlineColumn)
        XCTAssertEqual(
            controller.carousel.restingCenteredCardFrame(in: controller.view)?.midX ?? 0,
            Self.wideSize.width / 2,
            accuracy: 0.5)
    }

    // MARK: - Stacking

    /// Nested layers stack on the RIGHT card. A link tapped on the left one
    /// while a column is open therefore joins that column's stack; it never
    /// opens a third card.
    func testASecondLinkStacksOnTheOpenColumnRatherThanOpeningAnother() throws {
        let controller = makeController(size: Self.wideSize)
        let column = try XCTUnwrap(openColumn(on: controller))
        XCTAssertTrue(column.acceptsPushedLink)

        let second = withAnimationsDisabled {
            controller.openNestedReaderForTesting(
                url: URL(string: "https://example.com/deeper")!,
                sourcePointInWindow: CGPoint(x: 260, y: 500))
        }
        XCTAssertNil(second, "the open column took the link")
        XCTAssertTrue(controller.openInlineColumn === column)
        XCTAssertEqual(
            controller.children.filter { $0 is SplitWebOverlayViewController }.count, 1)
    }

    // MARK: - Helpers

    private func makeController(
        size: CGSize, itemCount: Int = 1
    ) -> ArticleCardsViewController {
        var items: [ReadingListItem] = []
        var contents: [UUID: ArticleContent] = [:]
        for index in 0..<itemCount {
            let item = ReadingListItem(
                seed: "column-\(index)",
                urlString: "https://example.com/column-\(index)",
                title: "Column \(index)",
                dateAdded: Date().addingTimeInterval(-Double(index)),
                state: .ready,
                wordCount: 600)
            items.append(item)
            contents[item.id] = UITestFixtures.sampleArticleContent(title: "Column \(index)")
        }
        ReadingListStore.shared.seedForTesting(items: items, contents: contents)

        let controller = ArticleCardsViewController()
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.isHidden = false
        self.window = window
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        window.layoutIfNeeded()
        controller.view.layoutIfNeeded()
        return controller
    }

    private func openColumn(
        on controller: ArticleCardsViewController
    ) -> SplitWebOverlayViewController? {
        let column = withAnimationsDisabled {
            controller.openNestedReaderForTesting(
                url: URL(string: "https://example.com/linked")!,
                sourcePointInWindow: CGPoint(x: 300, y: 500))
        }
        controller.view.layoutIfNeeded()
        return column
    }

    private func withAnimationsDisabled<T>(_ body: () -> T) -> T {
        let wereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(false)
        defer { UIView.setAnimationsEnabled(wereEnabled) }
        return body()
    }
}
