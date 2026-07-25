//
//  TableOfContentsWordStreamTests.swift
//  LunaTests
//

import LunaModels
import LunaReaderEngine
import Foundation
import XCTest
@testable import LunaAudioPlayback
@testable import LunaReaderUI

/// A table of contents renders in the scroll reader but is never READ. Four
/// consumers share one word-index space (RSVP frames, `WordMap` ranges,
/// read-aloud utterances, the background audio script) and all four have to agree
/// to skip it: if only some did, every position past the ToC would mean a
/// different word in each reader.
final class TableOfContentsWordStreamTests: XCTestCase {

    private func paragraph(_ text: String) -> ArticleContent.Block {
        ArticleContent.Block(kind: .paragraph, text: text, links: [])
    }

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

    /// Mirrors `WordMapTests`: block text concatenated with no title or spacing, so
    /// offsets are easy to reason about. Every block that renders gets a range —
    /// INCLUDING the ToC rows, which is the point: `WordMap` has to skip them on
    /// kind, not on a missing range.
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

    // MARK: - Destination lookup

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
