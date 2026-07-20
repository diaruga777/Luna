import LunaReaderUI
import UIKit
import XCTest

final class InlineReaderTabMetricsTests: XCTestCase {
    func testNoTabsHasNoScrollableContent() {
        let metrics = InlineReaderTabMetrics(
            availableWidth: 240, tabCount: 0, minimumTabWidth: 38)

        XCTAssertEqual(metrics.tabWidth, 0)
        XCTAssertEqual(metrics.contentWidth, 0)
        XCTAssertEqual(metrics.initialContentOffsetX, 0)
        XCTAssertFalse(metrics.scrolls)
    }

    func testTabsSplitAvailableWidthEvenlyWhenTheyFit() {
        let metrics = InlineReaderTabMetrics(
            availableWidth: 240, tabCount: 3, minimumTabWidth: 38)

        XCTAssertEqual(metrics.tabWidth, 80)
        XCTAssertEqual(metrics.contentWidth, 240)
        XCTAssertEqual(metrics.initialContentOffsetX, 0)
        XCTAssertFalse(metrics.scrolls)
    }

    func testCrowdedTabsKeepMinimumWidthAndStartAtRightEdge() {
        let metrics = InlineReaderTabMetrics(
            availableWidth: 180, tabCount: 6, minimumTabWidth: 38)

        XCTAssertEqual(metrics.tabWidth, 38)
        XCTAssertEqual(metrics.contentWidth, 228)
        XCTAssertEqual(metrics.initialContentOffsetX, 48)
        XCTAssertTrue(metrics.scrolls)
    }

    func testOverlayOwnsCustomPresentationTransition() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/linked"))
        let overlay = SplitWebOverlayViewController(
            url: url, shareProvider: nil, sourcePoint: CGPoint(x: 80, y: 300))

        XCTAssertEqual(overlay.modalPresentationStyle, .custom)
        XCTAssertTrue(overlay.transitioningDelegate === overlay)
    }

    func testCompletedDismissalRestoresOuterReaderExactlyOnce() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/linked"))
        let overlay = SplitWebOverlayViewController(
            url: url, shareProvider: nil, sourcePoint: CGPoint(x: 80, y: 300))
        var dismissalCount = 0
        overlay.onDismiss = { dismissalCount += 1 }
        let presenter = UIViewController()
        let presentation = try XCTUnwrap(overlay.presentationController(
            forPresented: overlay, presenting: presenter, source: presenter))

        presentation.dismissalTransitionDidEnd(false)
        XCTAssertEqual(dismissalCount, 0)

        presentation.dismissalTransitionDidEnd(true)
        presentation.dismissalTransitionDidEnd(true)
        XCTAssertEqual(dismissalCount, 1)
    }

    func testTabsHugTheirContentWhenThereIsRoom() {
        let metrics = InlineReaderTabMetrics(
            availableWidth: 300, idealWidths: [74, 112],
            minimumTabWidth: 38, spacing: -9)

        XCTAssertEqual(metrics.tabWidths, [74, 112])
        XCTAssertEqual(metrics.contentWidth, 177)
        XCTAssertFalse(metrics.scrolls)
    }

    func testOverlappingCrowdedTabsScrollFromRightEdge() {
        let metrics = InlineReaderTabMetrics(
            availableWidth: 80, idealWidths: [90, 110, 80],
            minimumTabWidth: 38, spacing: -9)

        XCTAssertEqual(metrics.tabWidths.count, 3)
        metrics.tabWidths.forEach { XCTAssertEqual($0, 38, accuracy: 0.001) }
        XCTAssertEqual(metrics.contentWidth, 96, accuracy: 0.001)
        XCTAssertEqual(metrics.initialContentOffsetX, 16, accuracy: 0.001)
        XCTAssertTrue(metrics.scrolls)
    }

    func testManyTabsAlwaysHaveOneFiniteWidthEach() {
        let metrics = InlineReaderTabMetrics(
            availableWidth: 260,
            idealWidths: Array(repeating: 120, count: 12),
            minimumTabWidth: 38,
            spacing: -9)

        XCTAssertEqual(metrics.tabWidths.count, 12)
        XCTAssertTrue(metrics.tabWidths.allSatisfy { $0.isFinite && $0 >= 38 })
        XCTAssertTrue(metrics.contentWidth.isFinite)
        XCTAssertTrue(metrics.scrolls)
    }

    func testTabsConsumeTopOfNormalCardFootprint() {
        let card = CGRect(x: 10, y: 120, width: 380, height: 650)
        let metrics = InlineReaderPresentationMetrics(
            cardFrameInWindow: card, tabHeight: 42)

        XCTAssertEqual(metrics.presentationFrameInWindow, card)
        XCTAssertEqual(metrics.cardFrameInWindow, CGRect(
            x: 10, y: 162, width: 380, height: 608))
        XCTAssertEqual(metrics.localCardFrame, CGRect(
            x: 0, y: 42, width: 380, height: 608))
    }
}
