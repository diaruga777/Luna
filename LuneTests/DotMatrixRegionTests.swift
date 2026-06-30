//
//  DotMatrixRegionTests.swift
//  LuneTests
//
//  Unit tests for the UIView-level changed-region diff (`DotMatrixRegion`) and for the
//  RabbitHole reader's use of it: a layer-2 push/pop must exclude the unchanged layer-0
//  lip rects from the wipe region so they never pixelate.
//

import LuneReaderUI
import LuneTransitions
import UIKit
import XCTest

final class DotMatrixRegionTests: XCTestCase {

    // MARK: - Changed-region union math

    func testNoChangeReturnsNil() {
        let items = [DotMatrixRegion.Item(id: 0, frame: CGRect(x: 0, y: 0, width: 100, height: 100))]
        XCTAssertNil(DotMatrixRegion.changedRegion(before: items, after: items))
    }

    func testMovedItemUnionsBeforeAndAfterFrames() {
        let before = [DotMatrixRegion.Item(id: 0, frame: CGRect(x: 0, y: 0, width: 50, height: 50))]
        let after = [DotMatrixRegion.Item(id: 0, frame: CGRect(x: 100, y: 100, width: 50, height: 50))]
        let region = DotMatrixRegion.changedRegion(before: before, after: after)
        // Union of the two 50×50 rects spans (0,0)…(150,150).
        XCTAssertEqual(region, CGRect(x: 0, y: 0, width: 150, height: 150))
    }

    func testAppearedItemContributesItsFrame() {
        let before: [DotMatrixRegion.Item] = []
        let after = [DotMatrixRegion.Item(id: 1, frame: CGRect(x: 10, y: 20, width: 30, height: 40))]
        XCTAssertEqual(DotMatrixRegion.changedRegion(before: before, after: after),
                       CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    func testDisappearedItemContributesItsFrame() {
        let before = [DotMatrixRegion.Item(id: 1, frame: CGRect(x: 5, y: 5, width: 10, height: 10))]
        let after: [DotMatrixRegion.Item] = []
        XCTAssertEqual(DotMatrixRegion.changedRegion(before: before, after: after),
                       CGRect(x: 5, y: 5, width: 10, height: 10))
    }

    func testStateChangeAloneIsAChange() {
        // Same frame, different opaque state token (e.g. a role change) → changed.
        let frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        let before = [DotMatrixRegion.Item(id: 0, frame: frame, state: "focused")]
        let after = [DotMatrixRegion.Item(id: 0, frame: frame, state: "ancestor")]
        XCTAssertEqual(DotMatrixRegion.changedRegion(before: before, after: after), frame)
    }

    func testUnchangedItemExcludedFromUnion() {
        // Item 0 unchanged (excluded); item 1 moves — only item 1's rects contribute.
        let unchanged = DotMatrixRegion.Item(id: 0, frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        let before = [unchanged, DotMatrixRegion.Item(id: 1, frame: CGRect(x: 100, y: 100, width: 10, height: 10))]
        let after = [unchanged, DotMatrixRegion.Item(id: 1, frame: CGRect(x: 200, y: 200, width: 10, height: 10))]
        let region = DotMatrixRegion.changedRegion(before: before, after: after)
        XCTAssertEqual(region, CGRect(x: 100, y: 100, width: 110, height: 110))
        // Critically, the unchanged item's (0,0,10,10) rect is NOT in the union.
        XCTAssertFalse(region!.contains(CGPoint(x: 5, y: 5)))
    }

    func testRegionClampedToBounds() {
        let before: [DotMatrixRegion.Item] = []
        let after = [DotMatrixRegion.Item(id: 0, frame: CGRect(x: -50, y: -50, width: 200, height: 200))]
        let bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        // Off-screen tucked frame is intersected with bounds.
        XCTAssertEqual(DotMatrixRegion.changedRegion(before: before, after: after, in: bounds),
                       CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    func testIsFullScreen() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
        XCTAssertTrue(DotMatrixRegion.isFullScreen(bounds, bounds: bounds))
        XCTAssertTrue(DotMatrixRegion.isFullScreen(bounds.insetBy(dx: 0.5, dy: 0.5), bounds: bounds))
        XCTAssertFalse(DotMatrixRegion.isFullScreen(
            CGRect(x: 14, y: 114, width: 386, height: 572), bounds: bounds))
    }

    // MARK: - RabbitHole layer-2 push/pop excludes the layer-0 lip

    // Mirrors RabbitHoleReaderViewController.placementItems: build changed-region items
    // from the layout's resting placements for a (focus, layerCount) arrangement.
    private let layout = RabbitHoleLayout()
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 800)
    private let safe = UIEdgeInsets(top: 60, left: 0, bottom: 40, right: 0)

    private func items(focus f: Int, count n: Int) -> [DotMatrixRegion.Item] {
        (0..<n).map { i in
            let p = layout.placement(layerIndex: i, focusedIndex: f, bounds: bounds, safeArea: safe)
            return DotMatrixRegion.Item(id: i, frame: p.cardFrame, state: "\(p.role)|\(p.cardAlpha > 0.001)")
        }
    }

    func testLayer2PushExcludesLayer0Lips() {
        // 2-layer stack (focus 1) diving to push layer 2 (focus 2, count 3). Layer 0 is an
        // ancestor on BOTH sides at the same inset step → unchanged → its top/bottom lip
        // rects must be OUTSIDE the wipe region.
        let region = DotMatrixRegion.changedRegion(
            before: items(focus: 1, count: 2), after: items(focus: 2, count: 3), in: bounds)
        XCTAssertNotNil(region)
        let r = region!
        XCTAssertFalse(DotMatrixRegion.isFullScreen(r, bounds: bounds))

        // Layer 0's resting frame (backmost, steps 0): a point inside its TOP lip
        // (between the safe-area top and the parent's first lip) must NOT be in the region.
        let topLipPoint = CGPoint(x: 7, y: safe.top + layout.lipHeight / 2)
        XCTAssertFalse(r.contains(topLipPoint),
                       "layer-0 top lip must stay static during a layer-2 push")
        // And a point in layer 0's BOTTOM lip.
        let bottomLipPoint = CGPoint(x: 7, y: bounds.height - safe.bottom - layout.lipHeight / 2)
        XCTAssertFalse(r.contains(bottomLipPoint),
                       "layer-0 bottom lip must stay static during a layer-2 push")
        // The focused content area (deep inset) IS inside the region — it changes.
        let focusedPoint = CGPoint(x: bounds.midX, y: bounds.midY)
        XCTAssertTrue(r.contains(focusedPoint))
    }

    func testLayer2PopExcludesLayer0Lips() {
        // Reverse: 3-layer stack (focus 2) popping to focus 1 (count 2). Same exclusion.
        let region = DotMatrixRegion.changedRegion(
            before: items(focus: 2, count: 3), after: items(focus: 1, count: 2), in: bounds)
        XCTAssertNotNil(region)
        let r = region!
        XCTAssertFalse(DotMatrixRegion.isFullScreen(r, bounds: bounds))
        XCTAssertFalse(r.contains(CGPoint(x: 7, y: safe.top + layout.lipHeight / 2)))
        XCTAssertFalse(r.contains(CGPoint(x: 7, y: bounds.height - safe.bottom - layout.lipHeight / 2)))
    }

    func testSingleAncestorPopCoversAllContent() {
        // Popping a 2-layer stack to the root (focus 1→0): the only ancestor becomes the
        // focused root, so all the on-screen CONTENT changes. The region spans the full
        // content rect (root's backmost card = bounds minus the safe-area margins); the
        // genuinely-static safe-area strips (status bar / home indicator) are excluded —
        // that's correct, those pixels never change.
        let region = DotMatrixRegion.changedRegion(
            before: items(focus: 1, count: 2), after: items(focus: 0, count: 1), in: bounds)
        XCTAssertNotNil(region)
        let r = region!
        // Full content width, and from the safe-area top to the safe-area bottom.
        XCTAssertEqual(r.minX, 0, accuracy: 0.5)
        XCTAssertEqual(r.maxX, bounds.width, accuracy: 0.5)
        XCTAssertEqual(r.minY, safe.top, accuracy: 0.5)
        XCTAssertEqual(r.maxY, bounds.height - safe.bottom, accuracy: 0.5)
    }
}
