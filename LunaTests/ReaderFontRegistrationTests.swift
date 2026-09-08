//
//  ReaderFontRegistrationTests.swift
//  LunaTests
//

import XCTest
import UIKit
import LunaDesignSystem

/// The three bundled reader families ship as `.ttf` files at the containing
/// app's bundle root (`Luna/Resources/Fonts/`), and `ReaderFont` registers them
/// with CoreText on first use. A file that stops being copied, or a lookup that
/// stops finding it, makes every reader fall back to the system face silently —
/// so assert the resolved family instead.
final class ReaderFontRegistrationTests: XCTestCase {

    func testEachBundledFamilyResolvesToItsOwnFace() {
        let expected: [(ReaderFont, String)] = [
            (.lexend, "Lexend"),
            (.literata, "Literata"),
            (.notoSans, "Noto Sans"),
        ]
        for (font, family) in expected {
            let resolved = font.font(size: 17, weight: .regular)
            XCTAssertEqual(resolved.familyName, family, "\(font) fell back to \(resolved.familyName)")
        }
    }

    func testLiterataResolvesAnItalicFace() {
        let italic = ReaderFont.literata.italicFont(size: 17)
        XCTAssertEqual(italic.familyName, "Literata")
        XCTAssertTrue(
            italic.fontDescriptor.symbolicTraits.contains(.traitItalic),
            "the bundled italic face did not register")
    }

    func testTheSystemDesignsStayOnTheSystemFace() {
        XCTAssertEqual(
            ReaderFont.system.font(size: 17, weight: .regular).familyName,
            UIFont.systemFont(ofSize: 17, weight: .regular).familyName)
    }
}
