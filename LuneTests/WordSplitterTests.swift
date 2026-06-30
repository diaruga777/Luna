//
//  WordSplitterTests.swift
//  LuneTests
//

import LuneReaderEngine
import XCTest
@testable import Lune

final class WordSplitterTests: XCTestCase {

    func testShortWordIsUnchanged() {
        XCTAssertEqual(WordSplitter.split("hello", maxCharacters: 12), ["hello"])
        XCTAssertEqual(WordSplitter.split("well-being", maxCharacters: 12), ["well-being"])
    }

    func testHyphenatedWordSplitsAtHyphenWithDuplicatedHyphen() {
        // 13 chars > 10: split at the hyphen, hyphen shown on both sides.
        XCTAssertEqual(
            WordSplitter.split("self-evidently", maxCharacters: 10),
            ["self-", "-evidently"])
    }

    func testMultipleHyphens() {
        XCTAssertEqual(
            WordSplitter.split("up-to-date-thing", maxCharacters: 6),
            ["up-", "-to-", "-date-", "-thing"])
    }

    func testLongUnhyphenatedWordIsHardWrapped() {
        // 20 chars, max 8 → chunks of 7 letters + a trailing hyphen, last bare.
        let parts = WordSplitter.split("supercalifragilistic", maxCharacters: 8)
        XCTAssertEqual(parts, ["superca-", "lifragi-", "listic"])
        XCTAssertTrue(parts.dropLast().allSatisfy { $0.hasSuffix("-") })
        XCTAssertTrue(parts.allSatisfy { $0.count <= 8 })
    }

    func testHyphenPartStillTooLongGetsHardWrapped() {
        // First hyphen segment "antidisestablishmentarianism-" is too long → wrapped.
        let parts = WordSplitter.split("antidisestablishmentarianism-x", maxCharacters: 10)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 10 })
        XCTAssertEqual(parts.last, "-x")
        // Reassembling (dropping the wrap hyphens and the duplicated boundary
        // hyphens) recovers the original letters.
        let reassembled = parts.joined().replacingOccurrences(of: "-", with: "")
        XCTAssertEqual(reassembled, "antidisestablishmentarianismx")
    }

    func testMaxOfOneOrZeroDoesNotSplit() {
        XCTAssertEqual(WordSplitter.split("toolong", maxCharacters: 1), ["toolong"])
        XCTAssertEqual(WordSplitter.split("toolong", maxCharacters: 0), ["toolong"])
    }
}
