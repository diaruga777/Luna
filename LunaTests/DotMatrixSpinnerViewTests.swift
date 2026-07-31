//
//  EclipseHorizonSpinnerViewTests.swift
//  LunaTests
//
//  API-contract coverage for Luna's shared eclipse-horizon activity indicator.
//

import LunaDesignSystem
import UIKit
import XCTest

final class EclipseHorizonSpinnerViewTests: XCTestCase {

    /// The intrinsic size matches the configured side length (so `sizeToFit()` and
    /// Auto Layout both place it like the activity indicator it replaced).
    func testIntrinsicContentSizeMatchesConfiguredSide() {
        let spinner = EclipseHorizonSpinnerView(side: 26)
        XCTAssertEqual(spinner.intrinsicContentSize, CGSize(width: 26, height: 26))

        let large = EclipseHorizonSpinnerView(side: 36)
        XCTAssertEqual(large.intrinsicContentSize, CGSize(width: 36, height: 36))
    }

    /// The black moon, horizon, head, pulse, and merge flare each have their own
    /// layer so the orbit work stays entirely in Core Animation.
    func testBuildsEclipseHorizonLayers() {
        let spinner = EclipseHorizonSpinnerView(side: 26)
        spinner.frame = CGRect(x: 0, y: 0, width: 26, height: 26)
        spinner.layoutIfNeeded()
        XCTAssertGreaterThanOrEqual(spinner.layer.sublayers?.count ?? 0, 7)
    }

    /// `hidesWhenStopped` defaults to true: hidden at rest, visible while animating,
    /// hidden again after `stopAnimating()`.
    func testHidesWhenStoppedLifecycle() {
        let spinner = EclipseHorizonSpinnerView()
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
        let spinner = EclipseHorizonSpinnerView()
        spinner.hidesWhenStopped = false
        XCTAssertFalse(spinner.isHidden)
        spinner.startAnimating()
        spinner.stopAnimating()
        XCTAssertFalse(spinner.isHidden)
    }

    /// Setting `color` leaves the moon black while rebuilding the horizon bloom.
    func testColorCanBeChanged() {
        let spinner = EclipseHorizonSpinnerView(side: 26)
        spinner.color = .systemRed
        spinner.frame = CGRect(x: 0, y: 0, width: 26, height: 26)
        spinner.layoutIfNeeded()
        XCTAssertEqual(spinner.color, .systemRed)
        XCTAssertGreaterThan(spinner.layer.sublayers?.count ?? 0, 0)
    }

    /// The stopped, visible state still draws a complete eclipse rather than a
    /// blank placeholder (useful for deterministic screenshots).
    func testStaticEclipseIsLayerBacked() {
        let spinner = EclipseHorizonSpinnerView(side: 26)
        spinner.hidesWhenStopped = false
        spinner.color = .label
        spinner.layoutIfNeeded()
        XCTAssertFalse(spinner.isHidden)
        XCTAssertGreaterThanOrEqual(spinner.layer.sublayers?.count ?? 0, 7)
    }
}
