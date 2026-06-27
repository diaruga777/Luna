//
//  RSVPEngineTests.swift
//  ClipTests
//

import ClipModels
import XCTest
@testable import Clip

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
        XCTAssertEqual(RSVPEngine.orpIndex(forLength: 1), 0)
        XCTAssertEqual(RSVPEngine.orpIndex(forLength: 2), 1)
        XCTAssertEqual(RSVPEngine.orpIndex(forLength: 5), 1)
        XCTAssertEqual(RSVPEngine.orpIndex(forLength: 6), 2)
        XCTAssertEqual(RSVPEngine.orpIndex(forLength: 9), 2)
        XCTAssertEqual(RSVPEngine.orpIndex(forLength: 14), 3)
    }

    func testSentenceAndParagraphFlags() {
        let engine = RSVPEngine(content: makeContent(["Hi there. Done", "Next"]))
        XCTAssertFalse(engine.words[0].endsSentence)   // "Hi"
        XCTAssertTrue(engine.words[1].endsSentence)    // "there."
        XCTAssertTrue(engine.words[2].endsParagraph)   // "Done" (last in block)
        XCTAssertTrue(engine.words[3].endsParagraph)   // "Next"
    }

    func testBaseDurationMatchesWPM() {
        let engine = RSVPEngine(content: makeContent(["abc abc"]))
        // Plain short word at 300 wpm = 200ms.
        XCTAssertEqual(engine.duration(at: 0, wpm: 300), 0.2, accuracy: 0.0001)
    }

    func testLongWordsShowLonger() {
        let engine = RSVPEngine(content: makeContent(["hi consideration extraordinarily"]))
        let short = engine.duration(at: 0, wpm: 300)
        let medium = engine.duration(at: 1, wpm: 300)   // 13 chars → 1.6 (also paragraph-end? no, index 1 of 3)
        let long = engine.duration(at: 2, wpm: 300)
        XCTAssertGreaterThan(medium, short)
        XCTAssertGreaterThanOrEqual(long, medium)
    }

    func testSentenceEndPausesLonger() {
        let engine = RSVPEngine(content: makeContent(["word word. word, word"]))
        let plain = engine.duration(at: 0, wpm: 300)
        let sentenceEnd = engine.duration(at: 1, wpm: 300)
        let clauseEnd = engine.duration(at: 2, wpm: 300)
        XCTAssertEqual(sentenceEnd, plain * 1.8, accuracy: 0.0001)
        XCTAssertEqual(clauseEnd, plain * 1.3, accuracy: 0.0001)
    }

    func testParagraphEndPausesLongest() {
        let engine = RSVPEngine(content: makeContent(["one two", "three"]))
        let paragraphEnd = engine.duration(at: 1, wpm: 300)
        XCTAssertEqual(paragraphEnd, 0.2 * 2.5, accuracy: 0.0001)
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

    func testSkipForwardMovesExactly25Words() {
        XCTAssertEqual(RSVPEngine.skipTarget(currentIndex: 10, by: 25, wordCount: 100), 35)
    }

    func testSkipBackwardMovesExactly25Words() {
        XCTAssertEqual(RSVPEngine.skipTarget(currentIndex: 40, by: -25, wordCount: 100), 15)
    }

    func testSkipForwardClampsToLastWord() {
        // 90 + 25 = 115, but the last valid index is 99.
        XCTAssertEqual(RSVPEngine.skipTarget(currentIndex: 90, by: 25, wordCount: 100), 99)
    }

    func testSkipBackwardClampsToZero() {
        XCTAssertEqual(RSVPEngine.skipTarget(currentIndex: 10, by: -25, wordCount: 100), 0)
    }

    func testSkipAtLastWordForwardStaysPut() {
        XCTAssertEqual(RSVPEngine.skipTarget(currentIndex: 99, by: 25, wordCount: 100), 99)
    }

    func testSkipAtFirstWordBackwardStaysPut() {
        XCTAssertEqual(RSVPEngine.skipTarget(currentIndex: 0, by: -25, wordCount: 100), 0)
    }

    func testSkipInShortDocumentClampsToLastWord() {
        // Fewer than 25 words: a forward skip lands on the final word.
        XCTAssertEqual(RSVPEngine.skipTarget(currentIndex: 0, by: 25, wordCount: 5), 4)
    }

    func testSkipInEmptyDocumentClampsToZero() {
        XCTAssertEqual(RSVPEngine.skipTarget(currentIndex: 0, by: 25, wordCount: 0), 0)
        XCTAssertEqual(RSVPEngine.skipTarget(currentIndex: 0, by: -25, wordCount: 0), 0)
    }
}
