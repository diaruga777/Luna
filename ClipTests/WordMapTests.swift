//
//  WordMapTests.swift
//  ClipTests
//

import ClipModels
import Foundation
import XCTest
@testable import Clip

/// Exercises `WordMap`'s tokenization (mirrors RSVPEngine: split on whitespace,
/// images contribute no words) and the binary search that maps a character
/// index back to a word index. Built from a hand-constructed `RenderedArticle`
/// so no UIKit rendering is needed.
final class WordMapTests: XCTestCase {

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

    private func paragraph(_ text: String) -> ArticleContent.Block {
        ArticleContent.Block(kind: .paragraph, text: text, links: [])
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

    // MARK: - wordIndex(nearCharacterIndex:)

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
}
