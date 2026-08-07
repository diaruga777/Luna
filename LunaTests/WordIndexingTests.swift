//
//  WordIndexingTests.swift
//  LunaTests
//

import AVFoundation
import Foundation
import LunaModels
import LunaReaderEngine
import XCTest
@testable import Luna
@testable import LunaAudioPlayback
@testable import LunaReaderUI

final class WordIndexingTests: XCTestCase {

    private func paragraph(_ text: String) -> ArticleContent.Block {
        ArticleContent.Block(kind: .paragraph, text: text, links: [])
    }

    // MARK: - WordSplitter

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

    // MARK: - WordMap
    //
    // Exercises `WordMap`'s tokenization (mirrors RSVPEngine: split on whitespace,
    // images contribute no words) and the binary search that maps a character
    // index back to a word index. Built from a hand-constructed `RenderedArticle`
    // so no UIKit rendering is needed.

    /// Builds a WordMap whose attributed string is just the blocks' text
    /// concatenated with no extra title/spacing, so the character offsets in the
    /// test are easy to reason about. `blockTextRanges` mark where each block's
    /// text sits in that string; image blocks get nil.
    private func makeMap(blocks: [ArticleContent.Block]) -> WordMap {
        var combined = ""
        var ranges: [NSRange?] = []
        for block in blocks {
            if block.kind == .image {
                ranges.append(nil)
                continue
            }
            let location = (combined as NSString).length
            ranges.append(NSRange(location: location, length: (block.text as NSString).length))
            combined += block.text
        }
        let content = ArticleContent(title: "t", blocks: blocks)
        let rendered = RenderedArticle(
            text: NSAttributedString(string: combined), blockTextRanges: ranges)
        return WordMap(content: content, rendered: rendered)
    }

    private func image() -> ArticleContent.Block {
        ArticleContent.Block(kind: .image, text: "", links: [], imageFileName: "x.jpg")
    }

    func testTokenizesOnWhitespace() {
        let map = makeMap(blocks: [paragraph("one two three")])
        XCTAssertEqual(map.wordCount, 3)
    }

    func testWordRangesPointAtTheTokens() {
        let map = makeMap(blocks: [paragraph("one two three")])
        // "one" at 0..3, "two" at 4..7, "three" at 8..13.
        XCTAssertEqual(map.attributedRange(forWord: 0), NSRange(location: 0, length: 3))
        XCTAssertEqual(map.attributedRange(forWord: 1), NSRange(location: 4, length: 3))
        XCTAssertEqual(map.attributedRange(forWord: 2), NSRange(location: 8, length: 5))
    }

    func testImageBlocksContributeNoWords() {
        let map = makeMap(blocks: [paragraph("alpha beta"), image(), paragraph("gamma")])
        XCTAssertEqual(map.wordCount, 3)
        XCTAssertEqual(
            map.attributedRange(forWord: 2)?.location,
            ("alpha beta" as NSString).length)
    }

    func testAttributedRangeOutOfBoundsReturnsNil() {
        let map = makeMap(blocks: [paragraph("only one two")])
        XCTAssertNil(map.attributedRange(forWord: 99))
        XCTAssertNil(map.attributedRange(forWord: -1))
    }

    func testCollapsesRepeatedWhitespace() {
        let map = makeMap(blocks: [paragraph("one   two")])
        XCTAssertEqual(map.wordCount, 2)
    }

    // MARK: - WordMap: wordIndex(nearCharacterIndex:)

    func testNearCharacterIndexInsideWord() {
        let map = makeMap(blocks: [paragraph("one two three")])
        XCTAssertEqual(map.wordIndex(nearCharacterIndex: 0), 0)   // start of "one"
        XCTAssertEqual(map.wordIndex(nearCharacterIndex: 5), 1)   // inside "two"
        XCTAssertEqual(map.wordIndex(nearCharacterIndex: 10), 2)  // inside "three"
    }

    func testNearCharacterIndexInWhitespaceSnapsToNextWord() {
        let map = makeMap(blocks: [paragraph("one two three")])
        // Char 3 is the space after "one"; the search returns the next word.
        XCTAssertEqual(map.wordIndex(nearCharacterIndex: 3), 1)
    }

    func testNearCharacterIndexBeyondEndClampsToLastWord() {
        let map = makeMap(blocks: [paragraph("one two three")])
        XCTAssertEqual(map.wordIndex(nearCharacterIndex: 9999), 2)
    }

    func testNearCharacterIndexEmptyMapReturnsNil() {
        let map = makeMap(blocks: [image()])
        XCTAssertEqual(map.wordCount, 0)
        XCTAssertNil(map.wordIndex(nearCharacterIndex: 0))
    }

    // MARK: - WordMarkerMapping
    //
    // `SpeechRenderer.makeWordMarkers(from:sampleRateRatio:)` rescales captured
    // (character range, native-sample-offset) pairs into the canonical sample
    // rate space. These tests feed it synthetic callback sequences — no real
    // synthesis — and check the resulting offsets are monotonic and within
    // bounds, per the plan's word-marker mapping requirement.

    func testOffsetsPassThroughUnchangedAtUnityRatio() {
        let ranges: [(range: NSRange, nativeFrameOffset: AVAudioFramePosition)] = [
            (NSRange(location: 0, length: 3), 0),
            (NSRange(location: 4, length: 5), 1000),
            (NSRange(location: 10, length: 4), 2500),
        ]

        let markers = SpeechRenderer.makeWordMarkers(from: ranges, sampleRateRatio: 1.0)

        XCTAssertEqual(markers.map(\.sampleOffset), [0, 1000, 2500])
        XCTAssertEqual(markers.map(\.utteranceRange), ranges.map(\.range))
    }

    func testOffsetsScaleBySampleRateRatio() {
        // e.g. native 22050 Hz -> canonical 44100 Hz: ratio 2.0.
        let ranges: [(range: NSRange, nativeFrameOffset: AVAudioFramePosition)] = [
            (NSRange(location: 0, length: 2), 0),
            (NSRange(location: 3, length: 2), 500),
            (NSRange(location: 6, length: 3), 1100),
        ]

        let markers = SpeechRenderer.makeWordMarkers(from: ranges, sampleRateRatio: 2.0)

        XCTAssertEqual(markers.map(\.sampleOffset), [0, 1000, 2200])
    }

    func testOffsetsRemainMonotonicNonDecreasingAfterScaling() {
        // Synthetic increasing sequence of callback offsets, as would occur
        // during a real render (words are spoken in order).
        let nativeOffsets: [AVAudioFramePosition] = [0, 120, 340, 900, 901, 1500]
        let ranges = nativeOffsets.enumerated().map { index, offset in
            (range: NSRange(location: index * 5, length: 4), nativeFrameOffset: offset)
        }

        let markers = SpeechRenderer.makeWordMarkers(from: ranges, sampleRateRatio: 1.333)

        let offsets = markers.map(\.sampleOffset)
        for (previous, next) in zip(offsets, offsets.dropFirst()) {
            XCTAssertLessThanOrEqual(previous, next, "scaled offsets must stay monotonic non-decreasing")
        }
    }

    func testOffsetsStayWithinBoundsOfScaledTotalDuration() {
        let totalNativeFrames: AVAudioFramePosition = 44100 // 1s @ 44100Hz native
        let ratio = 0.5 // e.g. downsampling to 22050Hz canonical
        let ranges: [(range: NSRange, nativeFrameOffset: AVAudioFramePosition)] = [
            (NSRange(location: 0, length: 1), 0),
            (NSRange(location: 2, length: 1), 22050),
            (NSRange(location: 4, length: 1), totalNativeFrames - 1),
        ]

        let markers = SpeechRenderer.makeWordMarkers(from: ranges, sampleRateRatio: ratio)

        let scaledTotal = AVAudioFramePosition((Double(totalNativeFrames) * ratio).rounded())
        for marker in markers {
            XCTAssertGreaterThanOrEqual(marker.sampleOffset, 0)
            XCTAssertLessThanOrEqual(marker.sampleOffset, scaledTotal)
        }
    }

    func testEmptyRangesProduceEmptyMarkers() {
        let markers = SpeechRenderer.makeWordMarkers(from: [], sampleRateRatio: 1.5)
        XCTAssertTrue(markers.isEmpty)
    }

    func testPreservesCountAndOrder() {
        let ranges: [(range: NSRange, nativeFrameOffset: AVAudioFramePosition)] = (0..<10).map {
            (range: NSRange(location: $0 * 3, length: 2), nativeFrameOffset: AVAudioFramePosition($0 * 100))
        }
        let markers = SpeechRenderer.makeWordMarkers(from: ranges, sampleRateRatio: 1.0)
        XCTAssertEqual(markers.count, ranges.count)
        for (marker, expected) in zip(markers, ranges) {
            XCTAssertEqual(marker.utteranceRange, expected.range)
        }
    }

    // MARK: - AudioWordIndexing
    //
    // Pure math behind `AudioPlaybackCenter`'s resume/seek/skip and word-event
    // mapping (`AudioWordIndexing`).

    private func block(_ index: Int, _ text: String) -> AudioScript.SpokenBlock {
        AudioScript.SpokenBlock(blockIndex: index, text: text)
    }

    // MARK: - AudioWordIndexing: Word counting

    func testWordCountMatchesAudioScriptRule() {
        XCTAssertEqual(AudioWordIndexing.wordCount(in: "one two three"), 3)
        XCTAssertEqual(AudioWordIndexing.wordCount(in: "  padded   spaces  "), 2)
        XCTAssertEqual(AudioWordIndexing.wordCount(in: ""), 0)
        XCTAssertEqual(AudioWordIndexing.wordCount(in: "line\nbreaks\tcount"), 3)
    }

    // MARK: - AudioWordIndexing: Block starts & position lookup

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

    // MARK: - AudioWordIndexing: UTF-16 word-offset mapping (word events)

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

    // MARK: - TableOfContentsWordStream
    //
    // A table of contents renders in the scroll reader but is never READ. Four
    // consumers share one word-index space (RSVP frames, `WordMap` ranges,
    // read-aloud utterances, the background audio script) and all four have to
    // agree to skip it: if only some did, every position past the ToC would mean
    // a different word in each reader.

    private func tocRow(_ text: String, anchorID: String) -> ArticleContent.Block {
        ArticleContent.Block(
            kind: .tableOfContents, text: text,
            links: [ArticleContent.Link(
                start: 0, length: (text as NSString).length,
                urlString: "https://example.com/post#\(anchorID)", anchorID: anchorID)])
    }

    private func heading(_ text: String, anchorID: String) -> ArticleContent.Block {
        ArticleContent.Block(kind: .heading, text: text, links: [], anchorID: anchorID)
    }

    /// Chapter marks up top, then the article they point into.
    private func articleWithTableOfContents() -> ArticleContent {
        // The rows deliberately share no word with the headings they point at, so
        // a leaked row is distinguishable from its destination.
        ArticleContent(title: "Post", blocks: [
            tocRow("Contents uno", anchorID: "one"),
            tocRow("Contents dos", anchorID: "two"),
            heading("First part", anchorID: "one"),
            paragraph("alpha beta gamma"),
            heading("Second part", anchorID: "two"),
            paragraph("delta epsilon"),
        ])
    }

    /// The same article with the chapter marks removed — the word stream both
    /// readers must produce.
    private func articleWithoutTableOfContents() -> ArticleContent {
        ArticleContent(
            title: "Post",
            blocks: articleWithTableOfContents().blocks.filter { $0.kind != .tableOfContents })
    }

    /// Mirrors the `WordMap` fixtures above: block text concatenated with no
    /// title or spacing, so offsets are easy to reason about. Every block that
    /// renders gets a range — INCLUDING the ToC rows, which is the point:
    /// `WordMap` has to skip them on kind, not on a missing range.
    private func makeWordMap(_ content: ArticleContent) -> WordMap {
        var combined = ""
        var ranges: [NSRange?] = []
        for block in content.blocks {
            if block.kind == .image {
                ranges.append(nil)
                continue
            }
            let location = (combined as NSString).length
            ranges.append(NSRange(location: location, length: (block.text as NSString).length))
            combined += block.text
        }
        return WordMap(
            content: content,
            rendered: RenderedArticle(
                text: NSAttributedString(string: combined), blockTextRanges: ranges))
    }

    func testRSVPSkipsTheTableOfContents() {
        let withToC = RSVPEngine(content: articleWithTableOfContents())
        let withoutToC = RSVPEngine(content: articleWithoutTableOfContents())
        XCTAssertEqual(withToC.words.map(\.text), withoutToC.words.map(\.text))
        XCTAssertFalse(withToC.words.contains { $0.text.contains("Contents") })
    }

    /// The alignment invariant: same count, and the same word at every index.
    func testWordMapAndRSVPStayInTheSameIndexSpace() {
        let content = articleWithTableOfContents()
        let engine = RSVPEngine(content: content)
        let map = makeWordMap(content)
        XCTAssertEqual(map.wordCount, engine.words.count)

        var combined = ""
        for block in content.blocks where block.kind != .image { combined += block.text }
        let text = combined as NSString
        for index in 0..<map.wordCount {
            guard let range = map.attributedRange(forWord: index) else {
                return XCTFail("word \(index) has no range")
            }
            XCTAssertEqual(text.substring(with: range), engine.words[index].text)
        }
    }

    func testAnInPageJumpIsNotOfferedAsALinkToOpen() {
        // A ToC row is out of the stream entirely, so take a footnote marker in
        // prose: it stays readable, but its jump must not become a link pill that
        // would reopen this same article.
        let text = "See the note below."
        let content = ArticleContent(title: "Post", blocks: [
            ArticleContent.Block(
                kind: .paragraph, text: text,
                links: [ArticleContent.Link(
                    start: 8, length: 4,
                    urlString: "https://example.com/post#note", anchorID: "note")]),
            heading("Notes", anchorID: "note"),
        ])
        let engine = RSVPEngine(content: content)
        XCTAssertEqual(engine.words.map(\.text), ["See", "the", "note", "below.", "Notes"])
        XCTAssertTrue(engine.words.allSatisfy { $0.url == nil })
    }

    func testReadAloudNeverSpeaksTheTableOfContents() {
        let content = articleWithTableOfContents()
        let spoken = SpeechController.speakableBlocks(content: content, spokenBlockIndices: nil)
        // The two ToC rows are gone; original block indices are preserved, so the
        // visual reader stays untrimmed.
        XCTAssertEqual(spoken.map(\.blockIndex), [2, 3, 4, 5])
    }

    /// The background audio script drops it too, at high precision — so the
    /// global "don't drop more than half the article" cap can't reinstate it.
    func testTheAudioScriptDropsTheTableOfContents() {
        let content = articleWithTableOfContents()
        let script = AudioTrimHeuristics.classify(content).heuristicScript(for: content)
        XCTAssertEqual(script.spokenBlocks.map(\.blockIndex), [2, 3, 4, 5])
    }

    // MARK: - TableOfContentsWordStream: Destination lookup

    func testAnchorLookupFindsTheDestinationBlock() {
        let content = articleWithTableOfContents()
        XCTAssertEqual(content.blockIndex(forAnchorID: "one"), 2)
        XCTAssertEqual(content.blockIndex(forAnchorID: "two"), 4)
        XCTAssertNil(content.blockIndex(forAnchorID: "three"))
    }

    /// Lookup is by id, not by index, so moving the lead image to block zero (as
    /// extraction does) can't misdirect a jump.
    func testAnchorLookupSurvivesBlockReordering() {
        var content = articleWithTableOfContents()
        content.blocks.insert(
            ArticleContent.Block(kind: .image, text: "", links: [], imageFileName: "hero.jpg"),
            at: 0)
        XCTAssertEqual(content.blockIndex(forAnchorID: "one"), 3)
        XCTAssertEqual(content.blocks[3].text, "First part")
    }
}
