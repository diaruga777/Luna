//
//  KeyboardAvoidanceTests.swift
//  ClipTests
//
//  Pure-geometry coverage for the keyboard-avoidance helpers used by the
//  onboarding identity screen.
//

import UIKit
import XCTest
@testable import Clip

final class KeyboardAvoidanceTests: XCTestCase {

    // MARK: - bottomInset

    /// When the keyboard overlaps the bottom of the scroll view, the inset equals
    /// the overlap height.
    func testBottomInsetIsOverlapHeight() {
        let scroll = CGRect(x: 0, y: 0, width: 390, height: 600)
        let keyboard = CGRect(x: 0, y: 400, width: 390, height: 300)   // covers 400…600 of the scroll
        let inset = KeyboardAvoidance.bottomInset(keyboardFrameInView: keyboard, scrollViewBounds: scroll)
        XCTAssertEqual(inset, 200, accuracy: 0.01)
    }

    /// A keyboard entirely below the scroll view (e.g. dismissed / off-screen)
    /// produces no inset.
    func testBottomInsetZeroWhenKeyboardBelowScroll() {
        let scroll = CGRect(x: 0, y: 0, width: 390, height: 600)
        let keyboard = CGRect(x: 0, y: 700, width: 390, height: 300)
        let inset = KeyboardAvoidance.bottomInset(keyboardFrameInView: keyboard, scrollViewBounds: scroll)
        XCTAssertEqual(inset, 0, accuracy: 0.01)
    }

    /// Never returns a negative inset even if the keyboard frame is fully above.
    func testBottomInsetNonNegative() {
        let scroll = CGRect(x: 0, y: 0, width: 390, height: 600)
        let keyboard = CGRect(x: 0, y: 800, width: 390, height: 300)
        let inset = KeyboardAvoidance.bottomInset(keyboardFrameInView: keyboard, scrollViewBounds: scroll)
        XCTAssertGreaterThanOrEqual(inset, 0)
    }

    // MARK: - contentOffsetToReveal

    /// A field hidden below the visible region scrolls up so its bottom (plus
    /// padding) lands at the bottom of the visible area.
    func testOffsetRevealsFieldHiddenBelow() throws {
        // Visible region is 0…300 (300pt tall after the keyboard takes the rest).
        // Field sits at 280…324 — its bottom is hidden behind the keyboard.
        let target = CGRect(x: 0, y: 280, width: 360, height: 44)
        let offset = KeyboardAvoidance.contentOffsetToReveal(
            targetFrame: target,
            currentOffsetY: 0,
            visibleHeight: 300,
            maxContentOffsetY: 1000,
            padding: 16)
        // desired = 324 + 16 - 300 = 40
        XCTAssertEqual(try XCTUnwrap(offset), 40, accuracy: 0.01)
    }

    /// A field already fully visible needs no scroll.
    func testOffsetNilWhenFieldVisible() {
        let target = CGRect(x: 0, y: 50, width: 360, height: 44)
        let offset = KeyboardAvoidance.contentOffsetToReveal(
            targetFrame: target,
            currentOffsetY: 0,
            visibleHeight: 300,
            maxContentOffsetY: 1000,
            padding: 16)
        XCTAssertNil(offset)
    }

    /// A field above the current visible region scrolls back up to its top.
    func testOffsetRevealsFieldAbove() throws {
        let target = CGRect(x: 0, y: 100, width: 360, height: 44)
        let offset = KeyboardAvoidance.contentOffsetToReveal(
            targetFrame: target,
            currentOffsetY: 200,   // scrolled past the field
            visibleHeight: 300,
            maxContentOffsetY: 1000,
            padding: 16)
        XCTAssertEqual(try XCTUnwrap(offset), 100, accuracy: 0.01)
    }

    /// The computed offset never exceeds the legal maximum content offset.
    func testOffsetClampedToMax() throws {
        let target = CGRect(x: 0, y: 980, width: 360, height: 44)
        let offset = KeyboardAvoidance.contentOffsetToReveal(
            targetFrame: target,
            currentOffsetY: 0,
            visibleHeight: 300,
            maxContentOffsetY: 500,
            padding: 16)
        XCTAssertEqual(try XCTUnwrap(offset), 500, accuracy: 0.01)
    }

    /// Returns nil when the clamped target equals the current offset (no movement).
    func testOffsetNilWhenClampMatchesCurrent() {
        let target = CGRect(x: 0, y: 980, width: 360, height: 44)
        let offset = KeyboardAvoidance.contentOffsetToReveal(
            targetFrame: target,
            currentOffsetY: 500,
            visibleHeight: 300,
            maxContentOffsetY: 500,
            padding: 16)
        XCTAssertNil(offset)
    }
}
