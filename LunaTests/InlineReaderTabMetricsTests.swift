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
            url: url, shareProvider: nil, lineHeight: 0, cutY: 300,
            topHalf: nil, bottomHalf: nil, sourcePoint: CGPoint(x: 80, y: 300))

        XCTAssertEqual(overlay.modalPresentationStyle, .custom)
        XCTAssertTrue(overlay.transitioningDelegate === overlay)
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
}
