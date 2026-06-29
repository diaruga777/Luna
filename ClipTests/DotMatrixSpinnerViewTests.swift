//
//  DotMatrixSpinnerViewTests.swift
//  ClipTests
//
//  API-contract coverage for the shared Dot Matrix `DotMatrixSpinnerView` that
//  replaced `UIActivityIndicatorView` app-wide: it must size itself, honor
//  `hidesWhenStopped`, build its dot matrix, and start/stop cleanly. Plus a
//  deterministic snapshot of the static (visible, stopped) matrix layout — the
//  running ripple is animation-driven and intentionally not snapshotted.
//

import ClipDesignSystem
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
}
