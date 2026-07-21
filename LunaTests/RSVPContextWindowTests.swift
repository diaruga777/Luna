//
//  RSVPContextWindowTests.swift
//  LunaTests
//
//  The surrounding-prose context slice shared by RSVPViewController's context
//  labels and LinkRSVPPreview's — neither had a direct test of the window
//  math before this was extracted.
//

import LunaReaderEngine
import LunaReaderUI
import XCTest

final class RSVPContextWindowTests: XCTestCase {
    private func words(_ texts: [String]) -> [RSVPWord] {
        texts.map {
            RSVPWord(text: $0, orpIndex: 0, endsSentence: false, endsParagraph: false, endsClause: false)
        }
    }

    func testContextSurroundsASingleWordWithinRadius() {
        let all = words((0..<20).map { "w\($0)" })
        // Word at index 10, radius 3: preceding w7..w9, following w11..w13.
        let context = RSVPContextWindow.context(around: 10..<11, words: all, radius: 3)
        XCTAssertEqual(context?.preceding, "w7 w8 w9")
        XCTAssertEqual(context?.following, "w11 w12 w13")
    }

    func testContextClampsAtTheStartOfTheDocument() {
        let all = words((0..<5).map { "w\($0)" })
        let context = RSVPContextWindow.context(around: 1..<2, words: all, radius: 10)
        XCTAssertEqual(context?.preceding, "w0")
        XCTAssertEqual(context?.following, "w2 w3 w4")
    }

    func testContextClampsAtTheEndOfTheDocument() {
        let all = words((0..<5).map { "w\($0)" })
        let context = RSVPContextWindow.context(around: 3..<4, words: all, radius: 10)
        XCTAssertEqual(context?.preceding, "w0 w1 w2")
        XCTAssertEqual(context?.following, "w4")
    }

    /// RSVP's Phrases mode excludes a whole phrase, not a single word.
    func testContextExcludesAMultiWordShownRange() {
        let all = words((0..<10).map { "w\($0)" })
        let context = RSVPContextWindow.context(around: 4..<6, words: all, radius: 2)
        XCTAssertEqual(context?.preceding, "w2 w3")
        XCTAssertEqual(context?.following, "w6 w7")
    }

    func testContextIsNilWhenShownRangeStartsOutOfBounds() {
        let all = words((0..<3).map { "w\($0)" })
        XCTAssertNil(RSVPContextWindow.context(around: 5..<6, words: all, radius: 2))
    }

    func testContextOnEmptyDocumentIsNil() {
        XCTAssertNil(RSVPContextWindow.context(around: 0..<1, words: [], radius: 5))
    }
}
