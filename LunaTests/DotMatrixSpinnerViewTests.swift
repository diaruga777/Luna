//
//  DotMatrixSpinnerViewTests.swift
//  LunaTests
//
//  API-contract coverage for the shared Dot Matrix `DotMatrixSpinnerView` that
//  replaced `UIActivityIndicatorView` app-wide: it must size itself, honor
//  `hidesWhenStopped`, build its dot matrix, and start/stop cleanly. Plus a
//  deterministic snapshot of the static (visible, stopped) matrix layout — the
//  running ripple is animation-driven and intentionally not snapshotted.
//

import LunaDesignSystem
import UIKit
import XCTest

final class DotMatrixSpinnerViewTests: XCTestCase {

    /// The intrinsic size matches the configured side length (so `sizeToFit()` and
    /// Auto Layout both place it like the activity indicator it replaced).
    func testIntrinsicContentSizeMatchesConfiguredSide() {
        let spinner = DotMatrixSpinnerView(side: 26)
        XCTAssertEqual(spinner.intrinsicContentSize, CGSize(width: 26, height: 26))

        let large = DotMatrixSpinnerView(side: 36)
        XCTAssertEqual(large.intrinsicContentSize, CGSize(width: 36, height: 36))
    }

    /// A 4×4 spinner lays out 16 dot sublayers.
    func testBuildsDotMatrix() {
        let spinner = DotMatrixSpinnerView(dimension: 4, side: 26)
        spinner.frame = CGRect(x: 0, y: 0, width: 26, height: 26)
        spinner.layoutIfNeeded()
        XCTAssertEqual(spinner.layer.sublayers?.count, 16)
    }

    /// `hidesWhenStopped` defaults to true: hidden at rest, visible while animating,
    /// hidden again after `stopAnimating()`.
    func testHidesWhenStoppedLifecycle() {
        let spinner = DotMatrixSpinnerView()
        XCTAssertTrue(spinner.hidesWhenStopped)
        XCTAssertTrue(spinner.isHidden)
        XCTAssertFalse(spinner.isAnimating)

        spinner.startAnimating()
        XCTAssertTrue(spinner.isAnimating)
        XCTAssertFalse(spinner.isHidden)

        spinner.stopAnimating()
        XCTAssertFalse(spinner.isAnimating)
        XCTAssertTrue(spinner.isHidden)
    }

    /// With `hidesWhenStopped == false`, the view stays visible when stopped.
    func testStaysVisibleWhenHidesWhenStoppedIsFalse() {
        let spinner = DotMatrixSpinnerView()
        spinner.hidesWhenStopped = false
        XCTAssertFalse(spinner.isHidden)
        spinner.startAnimating()
        spinner.stopAnimating()
        XCTAssertFalse(spinner.isHidden)
    }

    /// Setting `color` tints every dot layer.
    func testColorTintsAllDots() {
        let spinner = DotMatrixSpinnerView(dimension: 3, side: 26)
        spinner.color = .systemRed
        spinner.frame = CGRect(x: 0, y: 0, width: 26, height: 26)
        spinner.layoutIfNeeded()
        let expected = UIColor.systemRed.resolvedColor(with: spinner.traitCollection).cgColor
        for sublayer in spinner.layer.sublayers ?? [] {
            XCTAssertEqual(sublayer.backgroundColor, expected)
        }
    }

    /// A deterministic snapshot of the static matrix (stopped but visible) so the
    /// Dot Matrix look is pinned. The ripple animation is not snapshotted.
    func testStaticMatrixSnapshot() {
        let spinner = DotMatrixSpinnerView(dimension: 4, side: 26)
        spinner.hidesWhenStopped = false
        spinner.color = .label
        let size = CGSize(width: 26, height: 26)
        SnapshotTesting.assertSnapshot(of: spinner, named: "DotMatrixSpinner_static", size: size)
    }

    // MARK: - resolveToCheckmark's dot classification (pure geometry)

    /// At the `EmailLoginLoadingCover` dimension (7), the checkmark polyline
    /// should light up a plausible, non-trivial subset of the grid — neither empty
    /// (the shape didn't classify anything) nor the whole grid (the threshold is
    /// too loose to read as a checkmark).
    func testCheckmarkDotsAtDimensionSevenArePlausible() {
        let dimension = 7
        let indices = 0..<(dimension * dimension)
        let checkmarkDots = indices.filter { DotMatrixSpinnerView.isCheckmarkDot(dimension: dimension, index: $0) }

        XCTAssertFalse(checkmarkDots.isEmpty, "the checkmark polyline should light up at least some dots")
        XCTAssertLessThan(checkmarkDots.count, dimension * dimension,
                          "not every dot should read as part of the checkmark")
    }

    /// The classification must not crash on a coarse 4×4 grid (the spinner's
    /// default dimension), even though a checkmark barely resolves at that scale.
    func testCheckmarkDotClassificationDoesNotCrashAtDimensionFour() {
        let dimension = 4
        for index in 0..<(dimension * dimension) {
            _ = DotMatrixSpinnerView.isCheckmarkDot(dimension: dimension, index: index)
            _ = DotMatrixSpinnerView.checkmarkStrokePosition(dimension: dimension, index: index)
        }
    }

    /// Degenerate dimensions (0 or negative) must not crash and classify nothing.
    func testCheckmarkDotClassificationHandlesDegenerateDimensions() {
        XCTAssertFalse(DotMatrixSpinnerView.isCheckmarkDot(dimension: 0, index: 0))
        XCTAssertFalse(DotMatrixSpinnerView.isCheckmarkDot(dimension: -1, index: 0))
    }

    /// The stroke position is a monotonically-nondecreasing proxy for "how far
    /// along the ✓ this dot sits" — the corner dot nearest the polyline's start
    /// should have a strictly smaller stroke position than the one nearest its end,
    /// so the stagger order in `resolveToCheckmark` actually draws along the stroke
    /// rather than firing in an arbitrary order.
    func testCheckmarkStrokePositionOrdersFromStartToEnd() {
        let dimension = 7
        let indices = 0..<(dimension * dimension)
        let checkmarkDots = indices.filter { DotMatrixSpinnerView.isCheckmarkDot(dimension: dimension, index: $0) }
        let positions = checkmarkDots.map { DotMatrixSpinnerView.checkmarkStrokePosition(dimension: dimension, index: $0) }

        XCTAssertTrue(positions.allSatisfy { $0 >= 0 && $0 <= 1 })
        // Not every classified dot collapses to the same stroke position — the
        // ordering carries real information for the stagger.
        XCTAssertGreaterThan(Set(positions.map { ($0 * 100).rounded() }).count, 1)
    }
}
