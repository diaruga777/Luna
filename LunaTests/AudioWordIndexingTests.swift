//
//  AudioWordIndexingTests.swift
//  LunaTests
//

import XCTest
@testable import LunaAudioPlayback

/// Pure math behind `AudioPlaybackCenter`'s resume/seek/skip and word-event
/// mapping (`AudioWordIndexing`).
final class AudioWordIndexingTests: XCTestCase {

    private func block(_ index: Int, _ text: String) -> AudioScript.SpokenBlock {
        AudioScript.SpokenBlock(blockIndex: index, text: text)
    }

    // MARK: - Word counting

    func testWordCountMatchesAudioScriptRule() {
        XCTAssertEqual(AudioWordIndexing.wordCount(in: "one two three"), 3)
        XCTAssertEqual(AudioWordIndexing.wordCount(in: "  padded   spaces  "), 2)
        XCTAssertEqual(AudioWordIndexing.wordCount(in: ""), 0)
        XCTAssertEqual(AudioWordIndexing.wordCount(in: "line\nbreaks\tcount"), 3)
    }

    // MARK: - Block starts & position lookup

    func testBlockStartWordIndices() {
        let blocks = [block(0, "a b c"), block(2, "d"), block(5, "e f")]
        XCTAssertEqual(AudioWordIndexing.blockStartWordIndices(blocks), [0, 3, 4])
    }

    func testSpokenBlockPositionForWordIndex() {
        let starts = [0, 3, 4]
        XCTAssertEqual(AudioWordIndexing.spokenBlockPosition(forWordIndex: 0, in: starts), 0)
        XCTAssertEqual(AudioWordIndexing.spokenBlockPosition(forWordIndex: 2, in: starts), 0)
        XCTAssertEqual(AudioWordIndexing.spokenBlockPosition(forWordIndex: 3, in: starts), 1)
        XCTAssertEqual(AudioWordIndexing.spokenBlockPosition(forWordIndex: 4, in: starts), 2)
        XCTAssertEqual(AudioWordIndexing.spokenBlockPosition(forWordIndex: 999, in: starts), 2, "clamps past the end")
        XCTAssertEqual(AudioWordIndexing.spokenBlockPosition(forWordIndex: -1, in: starts), 0, "clamps below zero")
        XCTAssertEqual(AudioWordIndexing.spokenBlockPosition(forWordIndex: 5, in: []), 0, "empty script is position 0")
    }

    // MARK: - UTF-16 word-offset mapping (word events)

    func testWordStartUTF16Offsets() {
        XCTAssertEqual(AudioWordIndexing.wordStartUTF16Offsets(in: "one two three"), [0, 4, 8])
        XCTAssertEqual(AudioWordIndexing.wordStartUTF16Offsets(in: "  lead trail "), [2, 7])
        XCTAssertEqual(AudioWordIndexing.wordStartUTF16Offsets(in: ""), [])
    }

    func testWordStartUTF16OffsetsCountSurrogatePairsAsUTF16() {
        // "𝒜" is a surrogate pair (2 UTF-16 units): the second word starts at
        // UTF-16 offset 3, not character offset 2.
        XCTAssertEqual(AudioWordIndexing.wordStartUTF16Offsets(in: "𝒜 b"), [0, 3])
    }

    func testWordOffsetForUTF16Location() {
        let offsets = [0, 4, 8]
        XCTAssertEqual(AudioWordIndexing.wordOffset(forUTF16Location: 0, wordStartOffsets: offsets), 0)
        XCTAssertEqual(AudioWordIndexing.wordOffset(forUTF16Location: 3, wordStartOffsets: offsets), 0)
        XCTAssertEqual(AudioWordIndexing.wordOffset(forUTF16Location: 4, wordStartOffsets: offsets), 1)
        XCTAssertEqual(AudioWordIndexing.wordOffset(forUTF16Location: 100, wordStartOffsets: offsets), 2)
        XCTAssertEqual(AudioWordIndexing.wordOffset(forUTF16Location: 5, wordStartOffsets: []), 0)
    }
}
