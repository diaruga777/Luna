//
//  RSVPEngineTests.swift
//  ClipTests
//

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
}
