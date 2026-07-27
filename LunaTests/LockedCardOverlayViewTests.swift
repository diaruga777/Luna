//
//  LockedCardOverlayViewTests.swift
//  LunaTests
//

import LunaDesignSystem
import UIKit
import XCTest

/// The lock a paywalled card wears while it waits for the archive unlock flow.
///
/// The load-bearing property is the one that isn't visible: the overlay must not
/// take touches. It covers the whole card, and the card's own tap (→ unlock) and
/// long-press (→ Archive / Delete) have to pass straight through it — an overlay
/// that swallowed them would look perfectly right and break both gestures.
final class LockedCardOverlayViewTests: XCTestCase {

    private func mounted(caption: String? = "Locked — tap to unlock") -> LockedCardOverlayView {
        let overlay = LockedCardOverlayView(caption: caption)
        overlay.frame = CGRect(x: 0, y: 0, width: 340, height: 560)
        overlay.layoutIfNeeded()
        return overlay
    }

    func testOverlayAndEverySubviewRefuseTouches() {
        let overlay = mounted()
        XCTAssertFalse(overlay.isUserInteractionEnabled)
        // Belt and braces: a hit test through the middle of the card — right where
        // the glyph sits — must not land on the overlay or anything inside it.
        XCTAssertNil(overlay.hitTest(CGPoint(x: 170, y: 280), with: nil))
        XCTAssertNil(overlay.hitTest(CGPoint(x: 10, y: 10), with: nil))
    }

    func testGlyphAndWashAreBothTransparent() throws {
        let overlay = mounted()
        let glyph = try XCTUnwrap(overlay.subviews.compactMap { $0 as? UIImageView }.first)
        XCTAssertNotNil(glyph.image, "The lock glyph must resolve on this OS")
        XCTAssertLessThan(glyph.alpha, 1, "The glyph reads as a watermark, not a control")

        var alpha: CGFloat = 1
        overlay.backgroundColor?.getRed(nil, green: nil, blue: nil, alpha: &alpha)
        XCTAssertLessThan(alpha, 1, "The wash dims the card rather than replacing it")
        XCTAssertGreaterThan(alpha, 0, "…but it is a wash, not nothing")
    }

    func testCaptionCarriesTheAccessibilityLabelAndCanBeOmitted() {
        XCTAssertEqual(mounted().accessibilityLabel, "Locked — tap to unlock")
        XCTAssertTrue(mounted().isAccessibilityElement)

        let bare = mounted(caption: nil)
        XCTAssertFalse((bare.accessibilityLabel ?? "").isEmpty)
        let caption = bare.subviews.compactMap { $0 as? UILabel }.first
        XCTAssertEqual(caption?.isHidden, true)
    }

    @MainActor
    func testLockedCardOverlaySnapshot() {
        SnapshotTesting.assertSnapshot(
            of: mounted(), named: "locked-card-overlay",
            size: CGSize(width: 340, height: 560))
    }
}
