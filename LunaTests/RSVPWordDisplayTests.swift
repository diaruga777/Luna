//
//  RSVPWordDisplayTests.swift
//  LunaTests
//
//  Deterministic coverage for the ORP-highlighted attributed-string
//  construction shared by RSVPViewController's word label and
//  LinkRSVPPreview's focus label — neither had a direct test before this was
//  extracted (LunaTests/ReaderScreenTests.swift snapshot-tests the reader's
//  rendered pixels, but nothing pinned the underlying attributed string).
//

import LunaReaderEngine
import LunaReaderUI
import UIKit
import XCTest

final class RSVPWordDisplayTests: XCTestCase {
    private let font = UIFont.monospacedSystemFont(ofSize: 20, weight: .medium)

    private func word(_ text: String, orpIndex: Int? = nil) -> RSVPWord {
        RSVPWord(
            text: text, orpIndex: orpIndex ?? RSVPEngine.orpIndex(forLength: text.count),
            endsSentence: false, endsParagraph: false, endsClause: false, url: nil)
    }

    func testAttributedTextPreservesWordString() {
        let attributed = RSVPWordDisplay.attributedText(for: word("hello"), font: font)
        XCTAssertEqual(attributed.string, "hello")
    }

    func testORPLetterIsHighlightedInHighlightColor() {
        let highlight = UIColor.systemRed
        // "hello" → orpIndex(forLength: 5) == 1 → the "e".
        let attributed = RSVPWordDisplay.attributedText(
            for: word("hello"), font: font, highlightColor: highlight)
        var range = NSRange(location: 0, length: 0)
        let color = attributed.attribute(.foregroundColor, at: 1, effectiveRange: &range) as? UIColor
        XCTAssertEqual(color, highlight)
        XCTAssertEqual(range, NSRange(location: 1, length: 1))
    }

    func testNonORPLettersUseTextColor() {
        let base = UIColor.label
        let attributed = RSVPWordDisplay.attributedText(for: word("hello"), font: font, textColor: base)
        let color = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? UIColor
        XCTAssertEqual(color, base)
    }

    func testEmptyWordReturnsPlainStringWithoutCrashing() {
        let attributed = RSVPWordDisplay.attributedText(for: word(""), font: font)
        XCTAssertEqual(attributed.string, "")
        let offsets = RSVPWordDisplay.orpOffsets(for: word(""), font: font)
        XCTAssertEqual(offsets.prefixWidth, 0)
        XCTAssertEqual(offsets.orpWidth, 0)
    }

    func testOverlongORPIndexClampsToLastCharacter() {
        // A pathological orpIndex past the word's length must clamp rather
        // than crash or index out of range.
        let attributed = RSVPWordDisplay.attributedText(for: word("hi", orpIndex: 9), font: font)
        var range = NSRange(location: 0, length: 0)
        _ = attributed.attribute(.foregroundColor, at: 1, effectiveRange: &range)
        XCTAssertEqual(range, NSRange(location: 1, length: 1))
    }

    func testOrpOffsetsMatchPrefixAndLetterWidths() {
        let offsets = RSVPWordDisplay.orpOffsets(for: word("hello"), font: font)
        let expectedPrefix = NSAttributedString(string: "h", attributes: [.font: font]).size().width
        let expectedORP = NSAttributedString(string: "e", attributes: [.font: font]).size().width
        XCTAssertEqual(offsets.prefixWidth, expectedPrefix, accuracy: 0.01)
        XCTAssertEqual(offsets.orpWidth, expectedORP, accuracy: 0.01)
    }
}
