//
//  ChunkPlannerTests.swift
//  LunaTests
//

@testable import LunaReaderEngine
import LunaModels
import XCTest
@testable import Luna

final class ChunkPlannerTests: XCTestCase {

    /// Builds the RSVP word stream from a single paragraph (whitespace split,
    /// same tokenization the phrase engine consumes).
    private func words(_ paragraph: String) -> [RSVPWord] {
        let content = ArticleContent(
            title: "T", blocks: [ArticleContent.Block(kind: .paragraph, text: paragraph, links: [])])
        return RSVPEngine(content: content).words
    }

    private func chunkTexts(_ paragraph: String) -> [String] {
        ChunkPlanner.chunks(words: words(paragraph)).map(\.displayText)
    }

    // MARK: - Coverage / budget

    func testChunksTileEveryWordOnceInOrder() {
        let stream = words("one two three four five six seven eight nine ten")
        let chunks = ChunkPlanner.chunks(words: stream)
        XCTAssertEqual(chunks.first?.wordRange.lowerBound, 0)
        XCTAssertEqual(chunks.last?.wordRange.upperBound, stream.count)
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            XCTAssertEqual(a.wordRange.upperBound, b.wordRange.lowerBound)
        }
        // The reassembled words equal the original stream.
        XCTAssertEqual(chunks.flatMap(\.words), stream.map(\.text))
    }

    func testRespectsWordBudget() {
        let chunks = ChunkPlanner.chunks(
            words: words("alpha beta gamma delta epsilon zeta eta theta iota kappa"))
        XCTAssertTrue(chunks.allSatisfy { $0.wordRange.count <= ChunkPlanner.maxWordsPerChunk })
    }

    func testEmptyArticle() {
        XCTAssertTrue(ChunkPlanner.chunks(words: []).isEmpty)
    }

    // MARK: - Boundaries

    func testBreaksAtSentenceEnd() {
        let chunks = ChunkPlanner.chunks(words: words("hello there. world again now"))
        XCTAssertEqual(chunks.first?.wordRange, 0..<2)
        XCTAssertTrue(chunks.first?.endsSentence ?? false)
        XCTAssertEqual(chunks.first?.displayText, "hello there.")
    }

    /// A new phrase prefers to START at a preposition/conjunction (we break
    /// before it), keeping the prepositional phrase intact.
    func testBreaksBeforePhraseStarter() {
        let texts = chunkTexts("the quick brown fox jumped over the lazy dog")
        // "over" starts a new chunk rather than trailing the previous one.
        XCTAssertTrue(texts.contains { $0.hasPrefix("over") },
                      "expected a chunk to start at the preposition 'over': \(texts)")
    }

    /// A chunk must never END on a determiner/preposition ("the"/"in"): the bound
    /// word is pulled in with what follows.
    func testNeverEndsOnABinder() {
        for text in chunkTexts("she walked into the very large empty house quietly today") {
            let last = ReadingHeuristics.core(text.split(separator: " ").last.map(String.init) ?? "")
            XCTAssertFalse(ReadingHeuristics.leadingBinders.contains(last),
                           "chunk '\(text)' ends on a binder")
        }
    }

    // MARK: - Timing

    func testDurationHonorsWPMAndContent() {
        let chunks = ChunkPlanner.chunks(words: words("the cat sat. extraordinary complexity"))
        // A sentence-ending chunk pauses longer than the same words would plain.
        let sentence = chunks[0]
        XCTAssertTrue(sentence.endsSentence)
        XCTAssertGreaterThan(
            ChunkPlanner.duration(for: sentence, wpm: 300),
            ChunkPlanner.duration(
                for: TextChunk(wordRange: 0..<3, words: ["the", "cat", "sat"],
                               endsSentence: false, endsClause: false, endsParagraph: false),
                wpm: 300))
    }

    func testHardWordsDwellLongerThanFunctionWords() {
        let easy = TextChunk(wordRange: 0..<3, words: ["the", "of", "and"],
                             endsSentence: false, endsClause: false, endsParagraph: false)
        let hard = TextChunk(wordRange: 0..<3, words: ["extraordinary", "complexity", "demonstrates"],
                             endsSentence: false, endsClause: false, endsParagraph: false)
        XCTAssertGreaterThan(
            ChunkPlanner.duration(for: hard, wpm: 300),
            ChunkPlanner.duration(for: easy, wpm: 300))
    }

    func testDurationNeverBelowFloor() {
        let tiny = TextChunk(wordRange: 0..<1, words: ["a"],
                             endsSentence: false, endsClause: false, endsParagraph: false)
        XCTAssertGreaterThanOrEqual(
            ChunkPlanner.duration(for: tiny, wpm: 900), ChunkPlanner.minimumDisplay)
    }
}
