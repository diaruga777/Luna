//
//  RabbitHoleContentWipeRegionTests.swift
//  ClipTests
//
//  Pins the "header never pixelates" contract for the RabbitHole layer's mode-switch
//  wipe (Task 3). `RabbitHoleLayerViewController.setMode` confines the content-area
//  DotMatrixCrossfade to `contentWipeRegion(in:)` so the floating glass header (which
//  occupies `y: 0 ..< headerHeight`) is never inside the snapshotted/wiped sub-rect. The
//  segmented-control move is wiped separately by `DotMatrixSegmentedControl` (its own
//  view, also never snapshotting the header). Here we lock the geometry of that region.
//

import ClipReaderUI
import UIKit
import XCTest

final class RabbitHoleContentWipeRegionTests: XCTestCase {

    private let header = RabbitHoleLayerViewController.headerHeight

    func testContentWipeRegionStartsBelowTheHeaderBand() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let region = RabbitHoleLayerViewController.contentWipeRegion(in: bounds)
        // The wipe begins exactly at the bottom of the glass header — never above it.
        XCTAssertEqual(region.minY, header, accuracy: 0.001)
        XCTAssertGreaterThan(region.minY, 0)
    }

    func testContentWipeRegionNeverOverlapsTheHeaderBand() {
        let bounds = CGRect(x: 0, y: 0, width: 390, height: 844)
        let region = RabbitHoleLayerViewController.contentWipeRegion(in: bounds)
        let headerBand = CGRect(x: 0, y: 0, width: bounds.width, height: header)
        // The header band and the content wipe region must be disjoint (they may only
        // touch at the shared edge), so dissolving the content never pixelates the header.
        let overlap = region.intersection(headerBand)
        XCTAssertEqual(overlap.height, 0, accuracy: 0.001,
                       "Content wipe region must not overlap the header band")
    }

    func testContentWipeRegionSpansFullWidthAndRemainingHeight() {
        let bounds = CGRect(x: 0, y: 0, width: 320, height: 600)
        let region = RabbitHoleLayerViewController.contentWipeRegion(in: bounds)
        XCTAssertEqual(region.minX, 0, accuracy: 0.001)
        XCTAssertEqual(region.width, bounds.width, accuracy: 0.001)
        XCTAssertEqual(region.height, bounds.height - header, accuracy: 0.001)
    }

    func testContentWipeRegionClampsToZeroForCardsShorterThanTheHeader() {
        // A degenerate (very short) card never yields a negative-height region.
        let bounds = CGRect(x: 0, y: 0, width: 200, height: header - 10)
        let region = RabbitHoleLayerViewController.contentWipeRegion(in: bounds)
        XCTAssertGreaterThanOrEqual(region.height, 0)
    }
}
