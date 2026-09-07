//
//  TranscriptArticleBuilderTests.swift
//  LunaTests
//

import LunaModels
import LunaTranscribe
import XCTest

/// Timed segments → the reader article (`claudedocs/plans/transcription-plugins.md`
/// §5.2).
final class TranscriptArticleBuilderTests: XCTestCase {

    private let request = TranscriptionRequest(
        mediaURL: URL(string: "https://cdn.example.com/a.m4a")!, mediaKind: .audio,
        title: "A talk", author: "Someone", pluginID: "t")

    private func segment(_ start: TimeInterval, _ end: TimeInterval, _ text: String) -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text)
    }

    func testASilenceStartsANewParagraph() throws {
        let content = try TranscriptArticleBuilder.make(
            segments: [
                segment(0, 2, "Hello there."),
                segment(2.5, 4, "Still the same thought."),
                segment(6.5, 8, "A new one after a pause."),
            ],
            request: request)

        XCTAssertEqual(content.title, "A talk")
        XCTAssertEqual(content.author, "Someone")
        XCTAssertEqual(
            content.blocks.map(\.text),
            ["Hello there. Still the same thought.", "A new one after a pause."])
        XCTAssertTrue(content.blocks.allSatisfy { $0.kind == .paragraph })
    }

    func testALongParagraphEndsAtTheNextSentenceEndPastTheWordLimit() {
        let sentence = Array(repeating: "word", count: 30).joined(separator: " ") + "."
        let segments = (0..<6).map { i in
            segment(TimeInterval(i), TimeInterval(i) + 0.5, sentence)
        }
        let paragraphs = TranscriptArticleBuilder.paragraphs(from: segments)

        XCTAssertEqual(paragraphs.count, 2, "180 words break once, at 90")
        XCTAssertEqual(paragraphs[0].split(separator: " ").count, 90)
        XCTAssertEqual(paragraphs[1].split(separator: " ").count, 90)
    }

    func testAParagraphPastTheLimitWaitsForASentenceEnd() {
        let clause = Array(repeating: "word", count: 50).joined(separator: " ")
        let paragraphs = TranscriptArticleBuilder.paragraphs(from: [
            segment(0, 1, clause),
            segment(1, 2, clause),
            segment(2, 3, "and then it ends."),
            segment(3, 4, "Next."),
        ])
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertTrue(paragraphs[0].hasSuffix("and then it ends."))
        XCTAssertEqual(paragraphs[1], "Next.")
    }

    func testWhitespaceIsNormalizedAndEmptySegmentsAreDropped() {
        let paragraphs = TranscriptArticleBuilder.paragraphs(from: [
            segment(0, 1, "  Hello \n  there  "),
            segment(1, 2, "   "),
            segment(2, 3, "again."),
        ])
        XCTAssertEqual(paragraphs, ["Hello there again."])
    }

    func testTheLeadContentPrecedesTheTranscript() throws {
        let lead = ArticleContent(
            title: "A talk",
            blocks: [
                .init(kind: .image, text: "", links: [], imageURLString: "https://example.com/p.jpg"),
                .init(kind: .paragraph, text: "The description.", links: []),
            ])
        let request = TranscriptionRequest(
            mediaURL: URL(string: "https://cdn.example.com/a.m4a")!, mediaKind: .audio,
            title: "A talk", pluginID: "t", leadContent: lead)

        let content = try TranscriptArticleBuilder.make(
            segments: [segment(0, 1, "Spoken words.")], request: request)

        XCTAssertEqual(content.blocks.map(\.kind), [.image, .paragraph, .paragraph])
        XCTAssertEqual(content.blocks[1].text, "The description.")
        XCTAssertEqual(content.blocks[2].text, "Spoken words.")
    }

    func testNoWordsAtAllIsNoSpeech() {
        XCTAssertThrowsError(
            try TranscriptArticleBuilder.make(
                segments: [segment(0, 1, "  "), segment(1, 2, "")], request: request)
        ) { error in
            XCTAssertEqual(error as? TranscriptionError, .noSpeech)
        }
        XCTAssertThrowsError(try TranscriptArticleBuilder.make(segments: [], request: request))
    }

    func testAClosingQuoteStillEndsASentence() {
        let clause = Array(repeating: "word", count: 95).joined(separator: " ")
        let paragraphs = TranscriptArticleBuilder.paragraphs(from: [
            segment(0, 1, clause + " he said.\""),
            segment(1, 2, "Next."),
        ])
        XCTAssertEqual(paragraphs.count, 2)
    }
}
