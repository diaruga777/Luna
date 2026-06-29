//
//  DotMatrixSegmentedControlTests.swift
//  ClipTests
//
//  Unit tests for the pure segment-rect math behind the 3-phase Dot Matrix segmented-
//  control wipe (the "move" phase slides the overlay between these rects). The phase
//  sequencing itself is Metal/animation-driven and exercised on-device; here we pin the
//  geometry the move phase depends on. Reused by Task 2 (filter) and Task 3 (mode switch).
//

import ClipTransitions
import UIKit
import XCTest

final class DotMatrixSegmentedControlTests: XCTestCase {

    private let bounds = CGRect(x: 0, y: 0, width: 300, height: 32)

    func testEvenDivisionAcrossThreeSegments() {
        XCTAssertEqual(DotMatrixSegmentedControl.segmentRect(at: 0, in: bounds, segments: 3),
                       CGRect(x: 0, y: 0, width: 100, height: 32))
        XCTAssertEqual(DotMatrixSegmentedControl.segmentRect(at: 1, in: bounds, segments: 3),
                       CGRect(x: 100, y: 0, width: 100, height: 32))
        XCTAssertEqual(DotMatrixSegmentedControl.segmentRect(at: 2, in: bounds, segments: 3),
                       CGRect(x: 200, y: 0, width: 100, height: 32))
    }

    func testSegmentRectsTileTheBoundsWithoutGaps() {
        let segments = 4
        var union = CGRect.null
        for i in 0..<segments {
            union = union.union(DotMatrixSegmentedControl.segmentRect(at: i, in: bounds, segments: segments))
        }
        XCTAssertEqual(union, bounds)
    }

    func testOutOfRangeIndexClampsIntoBounds() {
        // A negative or too-large index clamps to the first/last segment so the moving
        // overlay never collapses to a zero rect.
        let first = DotMatrixSegmentedControl.segmentRect(at: -3, in: bounds, segments: 3)
        XCTAssertEqual(first, DotMatrixSegmentedControl.segmentRect(at: 0, in: bounds, segments: 3))
        let last = DotMatrixSegmentedControl.segmentRect(at: 99, in: bounds, segments: 3)
        XCTAssertEqual(last, DotMatrixSegmentedControl.segmentRect(at: 2, in: bounds, segments: 3))
    }

    func testZeroSegmentsFallsBackToFullBounds() {
        XCTAssertEqual(DotMatrixSegmentedControl.segmentRect(at: 0, in: bounds, segments: 0), bounds)
    }

    func testRespectsBoundsOrigin() {
        let offset = CGRect(x: 50, y: 10, width: 200, height: 32)
        XCTAssertEqual(DotMatrixSegmentedControl.segmentRect(at: 1, in: offset, segments: 2),
                       CGRect(x: 150, y: 10, width: 100, height: 32))
    }

    // The public 3-phase entry point is a graceful no-op (no crash, instant selection
    // already applied) when the pixel-wipe is unavailable — drive it through to confirm
    // the disabled fallback path is safe for any UISegmentedControl.
    func testAnimateSelectionChangeIsSafeWhenDisabledOrUnattached() {
        let control = UISegmentedControl(items: ["A", "B", "C"])
        control.frame = bounds
        control.selectedSegmentIndex = 2
        // Not in a window, Metal overlay won't attach → must fall through without throwing.
        DotMatrixSegmentedControl.animateSelectionChange(control, from: 0)
        XCTAssertEqual(control.selectedSegmentIndex, 2)
    }
}
