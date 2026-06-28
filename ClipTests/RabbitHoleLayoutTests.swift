//
//  RabbitHoleLayoutTests.swift
//  ClipTests
//

import ClipReaderUI
import UIKit
import XCTest
@testable import Clip

final class RabbitHoleLayoutTests: XCTestCase {

    private let layout = RabbitHoleLayout()
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
    private let safe = UIEdgeInsets(top: 60, left: 0, bottom: 40, right: 0)

    private func place(_ i: Int, _ focusedIndex: Int) -> RabbitHoleLayout.Placement {
        layout.placement(layerIndex: i, focusedIndex: focusedIndex, bounds: bounds, safeArea: safe)
    }

    func testRootAloneFillsScreen() {
        let p = place(0, 0)
        XCTAssertEqual(p.role, .focused)
        XCTAssertEqual(p.cardFrame.minX, 0, accuracy: 0.001)
        XCTAssertEqual(p.cardFrame.minY, safe.top, accuracy: 0.001)
        XCTAssertEqual(p.cardFrame.maxY, bounds.height - safe.bottom, accuracy: 0.001)
        XCTAssertEqual(p.chromeAlpha, 0, accuracy: 0.001)   // no lips when focused
    }

    func testFocusedInsetByVisibleAncestors() {
        // Two ancestors visible → focused layer inset two lip/indent steps.
        let p = place(2, 2)
        XCTAssertEqual(p.role, .focused)
        XCTAssertEqual(p.cardFrame.minX, 2 * layout.indentWidth, accuracy: 0.001)
        XCTAssertEqual(p.cardFrame.minY, safe.top + 2 * layout.lipHeight, accuracy: 0.001)
    }

    func testAncestorsShowLips() {
        let parent = place(1, 2)       // δ=1
        let grandparent = place(0, 2)  // δ=2
        XCTAssertEqual(parent.role, .ancestor)
        XCTAssertEqual(grandparent.role, .ancestor)
        XCTAssertEqual(parent.chromeAlpha, 1, accuracy: 0.001)
        XCTAssertEqual(grandparent.chromeAlpha, 1, accuracy: 0.001)
        // Grandparent is the backmost / largest card; the parent sits one step inside it.
        XCTAssertLessThan(grandparent.cardFrame.minX, parent.cardFrame.minX)
        XCTAssertLessThan(grandparent.cardFrame.minY, parent.cardFrame.minY)
        XCTAssertLessThan(parent.z, place(2, 2).z)   // focused is frontmost
    }

    func testThirdAncestorTucksOffscreen() {
        // At focus 3, layer 0 is the 3rd ancestor → tucked fully off the leading edge.
        let p = place(0, 3)
        XCTAssertEqual(p.role, .tucked)
        XCTAssertLessThanOrEqual(p.cardFrame.maxX, 0.5)   // entirely past the leading edge
    }

    func testTuckThresholdAtThreeDeep() {
        // Focus 2: all three (0,1,2) are visible — none tucked.
        XCTAssertNotEqual(place(0, 2).role, .tucked)
        // Focus 3: the oldest (layer 0) tucks; layers 1 and 2 remain visible ancestors.
        XCTAssertEqual(place(0, 3).role, .tucked)
        XCTAssertEqual(place(1, 3).role, .ancestor)
        XCTAssertEqual(place(2, 3).role, .ancestor)
        XCTAssertEqual(place(3, 3).role, .focused)
    }

    func testDeeperLayersAreMoreInset() {
        // With three layers shown, each deeper layer is inset one more lip/indent step
        // (root is the backmost full-screen card; the focused layer is the smallest).
        let root = place(0, 2).cardFrame
        let parent = place(1, 2).cardFrame
        let focused = place(2, 2).cardFrame
        XCTAssertLessThan(root.minX, parent.minX)
        XCTAssertLessThan(parent.minX, focused.minX)
        XCTAssertLessThan(root.minY, parent.minY)
        XCTAssertLessThan(parent.minY, focused.minY)
    }
}
