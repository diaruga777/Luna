//
//  RSVPEngineTests.swift
//  LunaTests
//

import LunaReaderEngine
import LunaModels
import XCTest
@testable import Luna

final class RSVPEngineTests: XCTestCase {

    private func makeContent(_ paragraphs: [String]) -> ArticleContent {
        ArticleContent(
            title: "T",
            blocks: paragraphs.map { ArticleContent.Block(kind: .paragraph, text: $0, links: []) })
    }

    func testTokenizesWordsAcrossBlocks() {
        let engine = RSVPEngine(content: makeContent(["One two three.", "Four five"]))
        XCTAssertEqual(engine.words.map(\.text), ["One", "two", "three.", "Four", "five"])
    }

    func testORPIndexByLength() {
        let cases: [(length: Int, orp: Int)] = [
            (1, 0), (2, 1), (5, 1), (6, 2), (9, 2), (14, 3),
        ]
        for testCase in cases {
            XCTAssertEqual(
                RSVPEngine.orpIndex(forLength: testCase.length),
                testCase.orp,
                "length \(testCase.length)")
        }
    }

    func testSentenceAndParagraphFlags() {
        let engine = RSVPEngine(content: makeContent(["Hi there. Done", "Next"]))
        XCTAssertFalse(engine.words[0].endsSentence)   // "Hi"
        XCTAssertTrue(engine.words[1].endsSentence)    // "there."
        XCTAssertTrue(engine.words[2].endsParagraph)   // "Done" (last in block)
        XCTAssertTrue(engine.words[3].endsParagraph)   // "Next"
    }

    /// Word duration at 300 wpm, in multiples of the plain-short-word base (200ms):
    /// clause and sentence ends dwell, a paragraph end dwells longest.
    func testWordDurationsAtStandardWPM() {
        let base = 0.2
        let cases: [(name: String, paragraphs: [String], index: Int, expected: Double)] = [
            ("plain short word = 200ms", ["abc abc"], 0, base),
            ("plain word in a mixed block", ["word word. word, word"], 0, base),
        ]
        for testCase in cases {
            let engine = RSVPEngine(content: makeContent(testCase.paragraphs))
            XCTAssertEqual(
                engine.duration(at: testCase.index, wpm: 300),
                testCase.expected,
                accuracy: 0.0001,
                testCase.name)
        }
    }

    func testLongWordsShowLonger() {
        let engine = RSVPEngine(content: makeContent(["hi consideration extraordinarily"]))
        let short = engine.duration(at: 0, wpm: 300)
        let medium = engine.duration(at: 1, wpm: 300)   // 13 chars → 1.6 (also paragraph-end? no, index 1 of 3)
        let long = engine.duration(at: 2, wpm: 300)
        XCTAssertGreaterThan(medium, short)
        XCTAssertGreaterThanOrEqual(long, medium)
    }

    func testDefaultDoesNotSplitLongWords() {
        let engine = RSVPEngine(content: makeContent(["supercalifragilisticexpialidocious"]))
        XCTAssertEqual(engine.words.map(\.text), ["supercalifragilisticexpialidocious"])
    }

    func testLongWordSplitsIntoFramesWhenCapped() {
        let engine = RSVPEngine(
            content: makeContent(["pneumonoultramicroscopic ok"]),
            maxCharactersPerWord: 10)
        // The long word becomes several hyphenated frames; "ok" stays one word.
        XCTAssertGreaterThan(engine.words.count, 2)
        XCTAssertTrue(engine.words.allSatisfy { $0.text.count <= 10 })
        XCTAssertEqual(engine.words.last?.text, "ok")
        // Only the final frame of the block carries the paragraph-end pause.
        XCTAssertTrue(engine.words.last?.endsParagraph ?? false)
        XCTAssertFalse(engine.words.first?.endsParagraph ?? true)
    }

    func testSplitParagraphEndOnLastPartOfLastToken() {
        // A long final token: its last part ends the paragraph, earlier parts don't.
        let engine = RSVPEngine(
            content: makeContent(["go pneumonoultramicroscopicsilicovolcanoconiosis"]),
            maxCharactersPerWord: 12)
        XCTAssertTrue(engine.words.last?.endsParagraph ?? false)
        XCTAssertEqual(engine.words.dropLast().filter { $0.endsParagraph }.count, 0)
    }

    func testWordsCarryLinkURL() {
        // "Visit Apple today" — link covers "Apple" (UTF-16 range 6..<11).
        let link = ArticleContent.Link(start: 6, length: 5, urlString: "https://apple.com")
        let block = ArticleContent.Block(kind: .paragraph, text: "Visit Apple today", links: [link])
        let engine = RSVPEngine(content: ArticleContent(title: "t", blocks: [block]))
        XCTAssertEqual(engine.words.first { $0.text == "Apple" }?.url?.absoluteString, "https://apple.com")
        XCTAssertNil(engine.words.first { $0.text == "Visit" }?.url)
        XCTAssertNil(engine.words.first { $0.text == "today" }?.url)
    }

    // MARK: - Skip target math

    func testSkipTargetMath() {
        let cases: [(name: String, index: Int, by: Int, wordCount: Int, expected: Int)] = [
            ("forward moves exactly 25 words", 10, 25, 100, 35),
            ("backward moves exactly 25 words", 40, -25, 100, 15),
            // 90 + 25 = 115, but the last valid index is 99.
            ("forward clamps to the last word", 90, 25, 100, 99),
            ("backward clamps to zero", 10, -25, 100, 0),
            ("at the last word, forward stays put", 99, 25, 100, 99),
            ("at the first word, backward stays put", 0, -25, 100, 0),
            // Fewer than 25 words: a forward skip lands on the final word.
            ("short document clamps to the last word", 0, 25, 5, 4),
            ("empty document, forward", 0, 25, 0, 0),
            ("empty document, backward", 0, -25, 0, 0),
        ]
        for testCase in cases {
            XCTAssertEqual(
                RSVPEngine.skipTarget(
                    currentIndex: testCase.index, by: testCase.by, wordCount: testCase.wordCount),
                testCase.expected,
                testCase.name)
        }
    }
}
