//
//  ChunkPlannerTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class ChunkPlannerTests: XCTestCase {

    /// Builds words + matching character ranges from a single paragraph the
    /// same way WordMap/RSVPEngine tokenize (whitespace split).
    private func wordsAndRanges(_ paragraph: String) -> ([RSVPWord], [NSRange]) {
        let content = ArticleContent(
            title: "T", blocks: [ArticleContent.Block(kind: .paragraph, text: paragraph, links: [])])
        let words = RSVPEngine(content: content).words
        let nsText = paragraph as NSString
        var ranges: [NSRange] = []
        var search = 0
        for token in paragraph.split(whereSeparator: { $0.isWhitespace }).map(String.init) {
            let r = nsText.range(of: token, range: NSRange(location: search, length: nsText.length - search))
            search = r.location + r.length
            ranges.append(r)
        }
        return (words, ranges)
    }

    func testChunksRespectWordBudget() {
        let (words, ranges) = wordsAndRanges("one two three four five six seven eight")
        let chunks = ChunkPlanner.chunks(words: words, wordRanges: ranges)
        XCTAssertTrue(chunks.allSatisfy { $0.wordRange.count <= ChunkPlanner.maxWordsPerChunk })
        // Chunks cover every word exactly once, in order.
        XCTAssertEqual(chunks.first?.wordRange.lowerBound, 0)
        XCTAssertEqual(chunks.last?.wordRange.upperBound, words.count)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(a.wordRange.upperBound, b.wordRange.lowerBound)
        }
    }

    func testBreaksAtSentenceEnd() {
        let (words, ranges) = wordsAndRanges("hello there. world again now")
        let chunks = ChunkPlanner.chunks(words: words, wordRanges: ranges)
        // "there." ends a sentence → the first chunk ends there.
        XCTAssertEqual(chunks.first?.wordRange, 0..<2)
        XCTAssertTrue(chunks.first?.endsSentence ?? false)
    }

    func testCharacterRangeUnionsWords() {
        let (words, ranges) = wordsAndRanges("alpha beta")
        let chunks = ChunkPlanner.chunks(words: words, wordRanges: ranges)
        // One chunk spanning "alpha beta" → range covers index 0 through end of "beta".
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].characterRange, NSRange(location: 0, length: 10))
    }

    func testDurationScalesWithWordCountAndPauses() {
        let (words, ranges) = wordsAndRanges("a b c. d e f")
        let chunks = ChunkPlanner.chunks(words: words, wordRanges: ranges)
        // First chunk "a b c." (3 words, sentence end) vs a plain 3-word chunk.
        let sentenceChunk = chunks[0]
        XCTAssertTrue(sentenceChunk.endsSentence)
        let plain = TextChunk(
            wordRange: 0..<3, characterRange: NSRange(location: 0, length: 5),
            endsSentence: false, endsClause: false, endsParagraph: false, characterCount: 3)
        XCTAssertGreaterThan(
            ChunkPlanner.duration(for: sentenceChunk, wpm: 300),
            ChunkPlanner.duration(for: plain, wpm: 300))
        // Per-word base honors WPM: a 3-word plain chunk at 300 wpm = 0.6s.
        XCTAssertEqual(ChunkPlanner.duration(for: plain, wpm: 300), 0.6, accuracy: 0.0001)
    }

    func testEmptyArticle() {
        XCTAssertTrue(ChunkPlanner.chunks(words: [], wordRanges: []).isEmpty)
    }
}
