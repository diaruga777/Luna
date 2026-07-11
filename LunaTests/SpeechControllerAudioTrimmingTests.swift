//
//  SpeechControllerAudioTrimmingTests.swift
//  LunaTests
//

import LunaModels
import XCTest
@testable import LunaReaderUI

/// Phase 6: the legacy extension-only read-aloud path
/// (`SpeechController`) now speaks a TRIMMED subset of an article's blocks.
/// `speakableBlocks(content:spokenBlockIndices:)` is the pure filtering logic
/// behind `SpeechController.init` — tested directly (no `AVSpeechSynthesizer`
/// involved) to pin the hard contract every other method in the class
/// depends on: each surviving entry keeps its ORIGINAL `content.blocks`
/// index, never renumbered, so `blockTextRanges[safe: block.blockIndex]`
/// (used by both `blockPosition(forAttributedLocation:)` and
/// `willSpeakRangeOfSpeechString`) keeps mapping correctly against the
/// UNTRIMMED visual reader regardless of which/how many blocks were filtered.
final class SpeechControllerAudioTrimmingTests: XCTestCase {

    private func block(_ text: String, kind: ArticleContent.Block.Kind = .paragraph) -> ArticleContent.Block {
        ArticleContent.Block(kind: kind, text: text, links: [])
    }

    private func content(_ blocks: [ArticleContent.Block]) -> ArticleContent {
        ArticleContent(title: "Title", blocks: blocks)
    }

    // MARK: - No filter (nil) = legacy passthrough behavior, unchanged

    func testNilSpokenBlockIndicesSpeaksEveryNonEmptyBlockInOrder() {
        let articleContent = content([block("Zero"), block(""), block("Two"), block("Three")])

        let speakable = SpeechController.speakableBlocks(content: articleContent, spokenBlockIndices: nil)

        // Block 1 is empty text and always skipped, filter or not.
        XCTAssertEqual(speakable.map(\.blockIndex), [0, 2, 3])
        XCTAssertEqual(speakable.map(\.text), ["Zero", "Two", "Three"])
    }

    // MARK: - Filtered: original indices preserved, not renumbered

    func testFilteringToASubsetPreservesOriginalBlockIndices() {
        let articleContent = content([
            block("By Jane Doe"), // dropped (byline-style, index 0)
            block("The actual first paragraph of real prose."), // kept, index 1
            block("Photo: a caption"), // dropped (caption-style, index 2)
            block("The second paragraph of real prose."), // kept, index 3
        ])
        // Simulates an `AudioScript.spokenBlocks.map(\.blockIndex)` that
        // dropped indices 0 and 2 (byline/caption), keeping 1 and 3 — NOT
        // contiguous, and NOT starting at 0.
        let spokenBlockIndices: Set<Int> = [1, 3]

        let speakable = SpeechController.speakableBlocks(content: articleContent, spokenBlockIndices: spokenBlockIndices)

        XCTAssertEqual(speakable.map(\.blockIndex), [1, 3], "kept blocks must keep their ORIGINAL index, not 0/1")
        XCTAssertEqual(speakable.map(\.text), [
            "The actual first paragraph of real prose.",
            "The second paragraph of real prose.",
        ])
    }

    func testEmptyTextBlocksAreAlwaysExcludedEvenIfNamedInTheFilter() {
        let articleContent = content([block("Kept"), block("")])
        // Even if a script's spokenBlocks somehow named the empty block, an
        // empty-text block never becomes speakable — matching the pre-Phase-6
        // invariant (`!$0.element.text.isEmpty` runs first).
        let speakable = SpeechController.speakableBlocks(content: articleContent, spokenBlockIndices: [0, 1])
        XCTAssertEqual(speakable.map(\.blockIndex), [0])
    }

    func testFilteringToAnEmptySetSpeaksNothing() {
        let articleContent = content([block("One"), block("Two")])
        let speakable = SpeechController.speakableBlocks(content: articleContent, spokenBlockIndices: [])
        XCTAssertTrue(speakable.isEmpty)
    }

    func testFilteringWithIndicesOutOfRangeIsHarmless() {
        let articleContent = content([block("One")])
        let speakable = SpeechController.speakableBlocks(content: articleContent, spokenBlockIndices: [0, 99])
        XCTAssertEqual(speakable.map(\.blockIndex), [0])
    }
}
