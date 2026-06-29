//
//  ArticleTextRendererProgressiveTests.swift
//  ClipTests
//
//  Covers the progressive (two-phase) load's renderer half: a `characterBudget`
//  prefix render must be a STRICT prefix of the full render — identical leading
//  attributed string, consistent block ranges, images gated to prefix blocks —
//  so the scroll reader can swap the full text in later while preserving scroll
//  position. Also pins that a `WordMap` rebuilt on the full render gains the
//  words that the prefix's map didn't have.
//

import ClipReaderUI
import ClipModels
import Foundation
import UIKit
import XCTest
@testable import Clip

final class ArticleTextRendererProgressiveTests: XCTestCase {

    private func paragraph(_ text: String) -> ArticleContent.Block {
        ArticleContent.Block(kind: .paragraph, text: text, links: [])
    }

    private func image(_ name: String) -> ArticleContent.Block {
        ArticleContent.Block(kind: .image, text: "", links: [], imageFileName: name)
    }

    /// A long article: title + several large paragraphs well past any small budget.
    private func longArticle() -> ArticleContent {
        let big = String(repeating: "word ", count: 200)   // ~1000 chars each
        return ArticleContent(
            title: "Progressive Fixture",
            blocks: [paragraph(big), paragraph(big), paragraph(big), paragraph(big)])
    }

    // MARK: - Prefix is a strict prefix of the full render

    func testPrefixIsAStrictPrefixOfFull() {
        let article = longArticle()
        let full = ArticleTextRenderer.render(article)
        let prefix = ArticleTextRenderer.render(article, characterBudget: 200)

        XCTAssertTrue(full.isComplete)
        XCTAssertFalse(prefix.isComplete, "200-char budget must truncate this long article")
        XCTAssertLessThan(prefix.text.length, full.text.length)
        // The prefix's characters are byte-for-byte the leading characters of the full
        // render (same fonts/spacing/title) — that's what makes the offset-preserving
        // swap seamless.
        let leading = full.text.attributedSubstring(
            from: NSRange(location: 0, length: prefix.text.length))
        XCTAssertEqual(prefix.text, leading)
    }

    func testPrefixIncludesTheBlockThatCrossesTheBudget() {
        // Budget 200, first paragraph ~1000 chars: the prefix includes the WHOLE first
        // block (the one that crosses the budget) so it always fills more than a screen.
        let article = longArticle()
        let prefix = ArticleTextRenderer.render(article, characterBudget: 200)
        // One title range slot is nil only for image blocks; here block 0 is text and
        // must be present with its full length.
        XCTAssertNotNil(prefix.blockTextRanges.first ?? nil)
        let firstRange = prefix.blockTextRanges[0]!
        XCTAssertEqual(firstRange.length,
                       (article.blocks[0].text as NSString).length,
                       "the budget-crossing block is included whole")
    }

    func testPrefixHasFewerBlocksThanFull() {
        let article = longArticle()
        let full = ArticleTextRenderer.render(article)
        let prefix = ArticleTextRenderer.render(article, characterBudget: 200)
        XCTAssertEqual(full.blockTextRanges.count, article.blocks.count)
        XCTAssertLessThan(prefix.blockTextRanges.count, full.blockTextRanges.count)
    }

    // MARK: - Short article: budget covers everything → complete, no truncation

    func testShortArticleUnderBudgetIsComplete() {
        let article = ArticleContent(
            title: "Tiny", blocks: [paragraph("just a few words here")])
        let prefix = ArticleTextRenderer.render(article, characterBudget: 700)
        XCTAssertTrue(prefix.isComplete, "an article shorter than the budget needs no swap")
        let full = ArticleTextRenderer.render(article)
        XCTAssertEqual(prefix.text, full.text)
        XCTAssertEqual(prefix.blockTextRanges.count, full.blockTextRanges.count)
    }

    // MARK: - Images gated to prefix blocks

    func testImagesBeyondPrefixAreExcluded() {
        // An image block AFTER the budget cutoff must not be in the prefix's imageRanges,
        // and the prefix must stop before it. (Even with the image file absent, an image
        // block in the prefix would still be counted as a block range entry — but here it
        // falls past the cutoff, so it's excluded entirely.)
        let big = String(repeating: "word ", count: 200)
        let article = ArticleContent(
            title: "With trailing image",
            blocks: [paragraph(big), paragraph(big), image("trailing.jpg")])
        let prefix = ArticleTextRenderer.render(article, characterBudget: 200)
        XCTAssertFalse(prefix.isComplete)
        // Only the first (budget-crossing) block is in; the trailing image block is past
        // the cutoff and excluded, so no image attachment ranges came from it.
        XCTAssertTrue(prefix.imageRanges.isEmpty)
        XCTAssertLessThan(prefix.blockTextRanges.count, article.blocks.count)
    }

    // MARK: - WordMap is richer on the full render than on the prefix

    func testFullRenderWordMapHasMoreWordsThanPrefix() {
        let article = longArticle()
        let prefix = ArticleTextRenderer.render(article, characterBudget: 200)
        let full = ArticleTextRenderer.render(article)
        let prefixMap = WordMap(content: article, rendered: prefix)
        let fullMap = WordMap(content: article, rendered: full)
        XCTAssertGreaterThan(fullMap.wordCount, prefixMap.wordCount,
                             "rebuilding the WordMap on the full text gains the deferred words")
        // A word deep in the article exists only in the full map.
        XCTAssertNil(prefixMap.attributedRange(forWord: fullMap.wordCount - 1))
        XCTAssertNotNil(fullMap.attributedRange(forWord: fullMap.wordCount - 1))
    }

    // MARK: - Scroll reader: Phase-2 swap preserves scroll position + rebuilds the map

    /// Opening a long article fresh from the top renders only the prefix first; once
    /// `prepareFullContent` lands the full text, the captured `contentOffset` is
    /// restored (seamless swap) and the word map covers the whole article.
    func testScrollReaderProgressiveSwapPreservesOffsetAndRebuildsMap() {
        let article = longArticle()
        var item = ReadingListItem(urlString: "https://example.com/p")
        item.state = .ready
        item.title = "Progressive Fixture"
        let reader = ScrollReaderViewController(item: item, content: article)

        // Force the view to load + lay out at a real size so the text view has a
        // scrollable content size to work against.
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()

        // Long article → the initial render is the (incomplete) prefix.
        XCTAssertFalse(reader.didLoadFullContentForTesting)
        let prefixLength = reader.renderedTextLengthForTesting

        // Scroll a little within the prefix, then run Phase 2.
        let textView = firstTextView(in: reader.view)
        textView?.contentOffset.y = 40
        let capturedOffset = textView?.contentOffset.y ?? 0

        reader.prepareFullContent()

        // The full build hops off-main then back; pump the run loop until it lands.
        let deadline = Date().addingTimeInterval(5)
        while !reader.didLoadFullContentForTesting, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertTrue(reader.didLoadFullContentForTesting, "Phase 2 must complete")
        XCTAssertGreaterThan(reader.renderedTextLengthForTesting, prefixLength,
                             "the full render is longer than the prefix")
        // The full word map now covers the whole article (all four big paragraphs).
        let fullMap = WordMap(content: article, rendered: ArticleTextRenderer.render(article))
        XCTAssertEqual(reader.wordCountForTesting, fullMap.wordCount)
        // Scroll position is preserved across the swap (the prefix is a strict prefix,
        // so the small in-prefix offset maps to the identical line in the full text).
        XCTAssertEqual(textView?.contentOffset.y ?? -1, capturedOffset, accuracy: 1.0)
    }

    private func firstTextView(in view: UIView) -> UITextView? {
        if let tv = view as? UITextView { return tv }
        for sub in view.subviews { if let found = firstTextView(in: sub) { return found } }
        return nil
    }
}
