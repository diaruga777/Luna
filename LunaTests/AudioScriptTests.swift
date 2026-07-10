//
//  AudioScriptTests.swift
//  LunaTests
//

import LunaAudioPlayback
import LunaModels
import XCTest

/// `AudioScript(passthrough:)` is the Phase-1 stub script builder: every
/// non-empty text block, verbatim, in document order. Later phases replace it
/// with real heuristic/LLM trimming — these tests only pin today's contract.
final class AudioScriptTests: XCTestCase {

    private func block(_ kind: ArticleContent.Block.Kind, _ text: String) -> ArticleContent.Block {
        ArticleContent.Block(kind: kind, text: text, links: [])
    }

    func testPassthroughKeepsEveryNonEmptyBlockInOrder() {
        let content = ArticleContent(title: "Title", blocks: [
            block(.heading, "A Headline"),
            block(.paragraph, "First paragraph of the article body."),
            block(.image, ""),
            block(.paragraph, "Second paragraph, right after the image."),
        ])

        let script = AudioScript(passthrough: content)

        XCTAssertEqual(script.spokenBlocks.map(\.blockIndex), [0, 1, 3])
        XCTAssertEqual(script.spokenBlocks.map(\.text), [
            "A Headline",
            "First paragraph of the article body.",
            "Second paragraph, right after the image.",
        ])
    }

    func testPassthroughDropsEmptyTextBlocks() {
        let content = ArticleContent(title: "Title", blocks: [
            block(.image, ""),
            block(.paragraph, ""),
            block(.paragraph, "Only real text."),
        ])

        let script = AudioScript(passthrough: content)

        XCTAssertEqual(script.spokenBlocks.count, 1)
        XCTAssertEqual(script.spokenBlocks.first?.blockIndex, 2)
        XCTAssertEqual(script.spokenBlocks.first?.text, "Only real text.")
    }

    func testPassthroughTotalWordCountSumsWhitespaceDelimitedWords() {
        let content = ArticleContent(title: "Title", blocks: [
            block(.paragraph, "Four little words here"),
            block(.paragraph, "Three more words"),
        ])

        let script = AudioScript(passthrough: content)

        XCTAssertEqual(script.totalWordCount, 7)
    }

    func testPassthroughSetsTheStubBuilderVersion() {
        let content = ArticleContent(title: "Title", blocks: [block(.paragraph, "Text.")])
        let script = AudioScript(passthrough: content)
        XCTAssertEqual(script.builderVersion, AudioScript.passthroughBuilderVersion)
    }

    func testEmptyArticleProducesEmptyScript() {
        let content = ArticleContent(title: "Title", blocks: [block(.image, "")])
        let script = AudioScript(passthrough: content)
        XCTAssertTrue(script.spokenBlocks.isEmpty)
        XCTAssertEqual(script.totalWordCount, 0)
    }

    func testScriptRoundTripsThroughCodable() throws {
        let content = ArticleContent(title: "Title", blocks: [block(.paragraph, "Round trip this.")])
        let script = AudioScript(passthrough: content)
        let data = try JSONEncoder().encode(script)
        let decoded = try JSONDecoder().decode(AudioScript.self, from: data)
        XCTAssertEqual(decoded, script)
    }
}
