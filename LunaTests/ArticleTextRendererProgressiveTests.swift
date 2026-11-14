//
//  ArticleTextRendererProgressiveTests.swift
//  LunaTests
//
//  Covers the progressive (two-phase) load's renderer half: a `characterBudget`
//  prefix render must be a STRICT prefix of the full render — identical leading
//  attributed string, consistent block ranges, images gated to prefix blocks —
//  so the scroll reader can swap the full text in later while preserving scroll
//  position. Also pins that a `WordMap` rebuilt on the full render gains the
//  words that the prefix's map didn't have.
//

@testable import LunaReaderUI
import LunaModels
import LunaStorage
import Foundation
import UIKit
import XCTest
@testable import Luna

final class ArticleTextRendererProgressiveTests: XCTestCase {

    private func paragraph(_ text: String) -> ArticleContent.Block {
        ArticleContent.Block(kind: .paragraph, text: text, links: [])
    }

    private func image(_ name: String) -> ArticleContent.Block {
        ArticleContent.Block(kind: .image, text: "", links: [], imageFileName: name)
    }

    private func remoteImage(width: Int, height: Int) -> ArticleContent.Block {
        ArticleContent.Block(
            kind: .image, text: "", links: [],
            imageURLString: "https://example.com/image.jpg",
            imageSize: ArticleContent.BlockImageSize(width: width, height: height))
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

    func testCardRenderCanReplaceTheInlineTitle() {
        let article = ArticleContent(
            title: "Card Header Title",
            author: "Reader Author",
            blocks: [paragraph("The article body remains available.")])

        let rendered = ArticleTextRenderer.render(article, includesTitle: false)
        let text = rendered.text.string

        XCTAssertFalse(text.contains(article.title))
        XCTAssertTrue(text.contains("Reader Author"))
        XCTAssertTrue(text.contains("The article body remains available."))
        XCTAssertEqual(rendered.blockTextRanges.count, article.blocks.count)
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

    func testImageInsidePrefixIsRenderedForInitialSnapshot() throws {
        let fileName = "prefix-\(UUID().uuidString).png"
        let fileURL = SavesStore.shared.articlesDirectory.appendingPathComponent(fileName)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        try makeTinyPNG().write(to: fileURL)

        let article = ArticleContent(
            title: "Image first",
            blocks: [image(fileName), paragraph("short body")])
        let prefix = ArticleTextRenderer.render(article, characterBudget: 700)

        XCTAssertTrue(prefix.isComplete)
        XCTAssertEqual(prefix.imageRanges.count, 1)
    }

    func testKnownSizeRemoteImageRendersPlaceholder() {
        let article = ArticleContent(
            title: "Image placeholder",
            blocks: [remoteImage(width: 1600, height: 900), paragraph("short body")])
        let rendered = ArticleTextRenderer.render(article, characterBudget: 700)

        var attachmentCount = 0
        rendered.text.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: rendered.text.length)
        ) { value, _, _ in
            if value is NSTextAttachment { attachmentCount += 1 }
        }
        XCTAssertEqual(attachmentCount, 1)
        XCTAssertTrue(rendered.imageRanges.isEmpty, "placeholder is layout-only until the file exists")
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
        var item = SavedItem(urlString: "https://example.com/p")
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

    @MainActor
    func testReusingReaderCancelsPendingFullContentWithoutReplacingNewArticle() async throws {
        var item = SavedItem(urlString: "https://example.com/old-render")
        item.state = .ready
        let reader = ScrollReaderViewController(item: item, content: longArticle())
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        reader.view.layoutIfNeeded()
        reader.prepareFullContent()
        let pending = try XCTUnwrap(reader.fullContentTaskForTesting)
        let replacement = ArticleContent(title: "The next article", blocks: [paragraph("This is the replacement.")])
        reader.configureForReuse(item: SavedItem(urlString: "https://example.com/new-render"), content: replacement)
        await pending.value
        XCTAssertTrue(pending.isCancelled)
        XCTAssertTrue(reader.didLoadFullContentForTesting)
        XCTAssertEqual(firstTextView(in: reader.view)?.text, ArticleTextRenderer.render(replacement).text.string)
    }

    func testCardWidthTransitionBuildsIndividualGlyphMovesAndRestoresLiveText() throws {
        var item = SavedItem(urlString: "https://example.com/reflow")
        item.state = .ready
        let content = ArticleContent(
            title: "Reflow",
            blocks: [paragraph(String(repeating: "Every character moves smoothly. ", count: 30))])
        let reader = ScrollReaderViewController(item: item, content: content)
        reader.view.frame = CGRect(x: 0, y: 0, width: 500, height: 800)
        reader.loadViewIfNeeded()
        reader.view.layoutIfNeeded()
        let textView = try XCTUnwrap(firstTextView(in: reader.view))

        let prepared = reader.prepareForCardViewportTransition(
            to: CGSize(width: 900, height: 1_000),
            destinationTopChromeInset: 80)

        if UIAccessibility.isReduceMotionEnabled {
            XCTAssertTrue(prepared)
            XCTAssertEqual(reader.viewportReflowGlyphCountForTesting, 0)
            reader.finishCardViewportTransition(completed: true)
            return
        }
        XCTAssertTrue(prepared)
        XCTAssertGreaterThan(reader.viewportReflowGlyphCountForTesting, 20)
        XCTAssertEqual(textView.alpha, 0, accuracy: 0.001,
                       "the live jumping TextKit layout stays hidden behind its glyphs")
        reader.animatePreparedCardViewportTransition()
        reader.view.frame = CGRect(x: 0, y: 0, width: 900, height: 1_000)
        reader.view.layoutIfNeeded()
        reader.finishCardViewportTransition(completed: true)
        XCTAssertEqual(reader.viewportReflowGlyphCountForTesting, 0)
        XCTAssertEqual(textView.alpha, 1, accuracy: 0.001)
    }

    @MainActor
    func testTapReflowKeepsCenterTextNearItsScreenPositionInBothDirections() throws {
        let article = ArticleContent(title: "Center reflow", blocks: [paragraph(String(
            repeating: "The same passage should stay close to the reader's eyes when the layout changes. ",
            count: 160))])
        var item = SavedItem(urlString: "https://example.com/center-reflow")
        item.lastScrollOffset = 4_000
        let reader = ScrollReaderViewController(item: item, content: article, includesArticleTitle: false)
        reader.view.frame = CGRect(x: 0, y: 120, width: 350, height: 600)
        reader.view.layoutIfNeeded()
        let text = try XCTUnwrap(firstTextView(in: reader.view))

        for frame in [CGRect(x: 0, y: 0, width: 650, height: 800),
                      CGRect(x: 0, y: 120, width: 350, height: 600)] {
            let source = reader.view.frame
            let manager = text.layoutManager
            let container = text.textContainer
            let center = CGPoint(x: text.bounds.midX - text.textContainerInset.left,
                                 y: text.bounds.midY - text.textContainerInset.top)
            let glyph = manager.glyphIndex(for: center, in: container)
            let characters = manager.characterRange(forGlyphRange: NSRange(location: glyph, length: 1),
                                                     actualGlyphRange: nil)
            func screenY() -> CGFloat {
                let range = manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
                return reader.view.frame.minY + manager.boundingRect(forGlyphRange: range, in: container).midY
                    + text.textContainerInset.top - text.contentOffset.y
            }

            let before = screenY()
            XCTAssertTrue(reader.prepareForCardViewportTransition(
                to: frame.size, originDelta: CGPoint(x: 0, y: frame.minY - source.minY)))
            reader.animatePreparedCardViewportTransition()
            reader.view.frame = frame
            reader.view.layoutIfNeeded()
            reader.finishCardViewportTransition(completed: true)
            XCTAssertEqual(screenY(), before, accuracy: 45,
                           "The passage at the screen center should move less than two lines")
        }
    }

    @MainActor
    func testInteractiveWidthChangesPreserveVisibleLinesAndReflowIncomingLines() throws {
        var item = SavedItem(urlString: "https://example.com/stable-lines")
        item.state = .ready
        let article = ArticleContent(title: "Stable lines", blocks: [paragraph(String(
            repeating: "Existing words stay on their original line while new lines fill the available column. ",
            count: 120))])
        let reader = ScrollReaderViewController(item: item, content: article)
        reader.view.frame = CGRect(x: 0, y: 0, width: 350, height: 600)
        reader.view.layoutIfNeeded()
        let text = try XCTUnwrap(firstTextView(in: reader.view))
        text.contentOffset.y = 5_000
        reader.scrollViewDidScroll(text)
        let originalString = text.text

        func visibleLines() -> [(NSRange, CGRect)] {
            text.layoutManager.ensureLayout(for: text.textContainer)
            var result: [(NSRange, CGRect)] = []
            text.layoutManager.enumerateLineFragments(forGlyphRange: NSRange(
                location: 0, length: text.layoutManager.numberOfGlyphs)) { rect, _, _, glyphs, _ in
                let screen = text.convert(rect.offsetBy(dx: text.textContainerInset.left,
                    dy: text.textContainerInset.top), to: reader.view)
                if screen.intersects(CGRect(origin: .zero, size: text.bounds.size)) {
                    result.append((text.layoutManager.characterRange(
                        forGlyphRange: glyphs, actualGlyphRange: nil), screen))
                }
            }
            return result
        }
        func resize(to width: CGFloat) {
            reader.prepareForCardViewportTransition(
                to: CGSize(width: width, height: 600), preservingVisibleLines: true)
            XCTAssertEqual(reader.viewportReflowGlyphCountForTesting, 0)
            XCTAssertEqual(text.alpha, 1)
            reader.view.frame.size.width = width
            reader.view.layoutIfNeeded()
            reader.finishCardViewportTransition(completed: true)
        }
        func assertPreserved(_ before: [(NSRange, CGRect)], file: StaticString = #filePath, line: UInt = #line) {
            let after = visibleLines()
            for (range, rect) in before {
                let matching = after.first { $0.0 == range }
                XCTAssertNotNil(matching, "Visible line changed its characters: \(range)", file: file, line: line)
                if let matching {
                    XCTAssertEqual(matching.1.width, rect.width, accuracy: 0.5, file: file, line: line)
                    XCTAssertEqual(matching.1.minY, rect.minY, accuracy: 0.5, file: file, line: line)
                }
            }
            XCTAssertEqual(text.text, originalString, "Layout must not edit the article")
        }

        func displayedX(for range: NSRange) throws -> CGFloat {
            let start = try XCTUnwrap(text.position(from: text.beginningOfDocument, offset: range.location))
            let end = try XCTUnwrap(text.position(from: start, offset: 1))
            return text.convert(text.firstRect(for: try XCTUnwrap(text.textRange(from: start, to: end))), to: reader.view).minX
        }
        let narrow = visibleLines()
        let normalTextX = try displayedX(for: XCTUnwrap(narrow.first).0)
        XCTAssertGreaterThan(narrow.count, 5)
        resize(to: 600)
        assertPreserved(narrow)

        // Cross the preservation boundary a few points at a time. Reflow
        // above the viewport must not move any line that is still visible.
        for step in 0..<100 {
            let before = visibleLines()
            text.contentOffset.y += 7
            reader.scrollViewDidScroll(text)
            let after = visibleLines()
            for (range, rect) in before where rect.maxY > 7 {
                let match = try XCTUnwrap(after.first(where: { $0.0 == range }),
                    "Visible line changed at step \(step): \(range), \(rect), after: \(after.map { $0.0 })")
                XCTAssertEqual(match.1.minY, rect.minY - 7, accuracy: 0.5)
                XCTAssertEqual(match.1.width, rect.width, accuracy: 0.5)
            }
        }
        let wide = visibleLines()
        XCTAssertTrue(wide.allSatisfy { $0.1.width > narrow[0].1.width + 100 },
                      "Incoming lines must fill the expanded column")
        text.contentOffset.y -= 700
        reader.scrollViewDidScroll(text)
        let beforeContraction = visibleLines()
        resize(to: 350)
        assertPreserved(beforeContraction)
        XCTAssertLessThanOrEqual(text.contentSize.width, text.bounds.width + 0.5,
                                 "Clipped old lines must not make the article scroll horizontally")

        for step in 0..<100 {
            let before = visibleLines()
            text.contentOffset.y -= 7
            reader.scrollViewDidScroll(text)
            let after = visibleLines()
            for (range, rect) in before where rect.minY + 7 < reader.view.bounds.height {
                let match = try XCTUnwrap(after.first(where: { $0.0 == range }),
                    "A visible line changed while scrolling up at step \(step): \(range), \(rect), after \(after.map { $0.0 })")
                XCTAssertEqual(match.1.minY, rect.minY + 7, accuracy: 0.5)
                XCTAssertEqual(match.1.width, rect.width, accuracy: 0.5)
            }
        }
        let returnedNarrow = visibleLines()
        XCTAssertEqual(try displayedX(for: XCTUnwrap(returnedNarrow.first).0), normalTextX, accuracy: 0.5,
                       "Retained wide lines must not shift the canvas for newly revealed narrow text")
        XCTAssertTrue(returnedNarrow.allSatisfy { $0.1.width <= narrow[0].1.width + 0.5 },
                      "Returning text must fit the current narrow width, including the short seam line")
        XCTAssertGreaterThan(returnedNarrow.filter { abs($0.1.width - narrow[0].1.width) < 0.5 }.count, 10)

        // Tap-driven transitions still reflow the live text to one uniform column.
        XCTAssertTrue(reader.prepareForCardViewportTransition(to: CGSize(width: 600, height: 600)),
                      "A tap must reflow a retained column even when its canvas already has the target width")
        reader.animatePreparedCardViewportTransition()
        reader.view.frame.size.width = 600
        reader.view.layoutIfNeeded()
        reader.finishCardViewportTransition(completed: true)
        XCTAssertTrue(visibleLines().allSatisfy { $0.1.width > narrow[0].1.width + 100 })
    }

    @MainActor
    func testAnimatedCardExpansionKeepsRetainedLinesAtTheirScreenX() throws {
        let animationsWereEnabled = UIView.areAnimationsEnabled
        UIView.setAnimationsEnabled(true)
        defer { UIView.setAnimationsEnabled(animationsWereEnabled) }
        var item = SavedItem(urlString: "https://example.com/stationary-lines")
        item.state = .ready
        let reader = ScrollReaderViewController(item: item, content: ArticleContent(
            title: "Stationary lines", blocks: [paragraph(String(
                repeating: "These existing rows should never blink sideways as the card expands. ", count: 100))]))
        let host = UIViewController()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .dark
        host.view.backgroundColor = .black
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.addChild(reader)
        reader.view.frame = CGRect(x: 26, y: 80, width: 350, height: 600)
        host.view.addSubview(reader.view)
        reader.didMove(toParent: host)
        reader.view.layoutIfNeeded()
        let text = try XCTUnwrap(firstTextView(in: reader.view))
        text.contentOffset.y = 150
        reader.scrollViewDidScroll(text)

        reader.prepareForCardViewportTransition(
            to: CGSize(width: 402, height: 600), preservingVisibleLines: true)
        let retainedLine = try XCTUnwrap(text.subviews.compactMap { $0 as? UIImageView }.first)
        let sourceX = retainedLine.convert(.zero, to: window).x
        let sourceWidth = retainedLine.bounds.width
        let sourceOffset = text.contentOffset.y
        // Commit the source frames before starting the card's transaction.
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        let finished = expectation(description: "card expansion")
        defer { wait(for: [finished], timeout: 2) }
        UIView.animate(withDuration: 0.32, delay: 0, options: [.curveEaseInOut, .allowUserInteraction]) {
            reader.view.frame = CGRect(x: 0, y: 80, width: 402, height: 600)
            reader.view.layoutIfNeeded()
        } completion: { _ in finished.fulfill() }

        for _ in 0..<8 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            let windowLayer = try XCTUnwrap(window.layer.presentation())
            let presentation = try XCTUnwrap(retainedLine.layer.presentation())
            XCTAssertEqual(presentation.convert(.zero, to: windowLayer).x, sourceX, accuracy: 0.5,
                "The live text canvas must stay at its screen X throughout the animation")
            XCTAssertEqual(presentation.bounds.width, sourceWidth, accuracy: 0.5)
            XCTAssertEqual(text.contentOffset.y, sourceOffset, accuracy: 0.01)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        XCTAssertEqual(retainedLine.convert(.zero, to: window).x, sourceX, accuracy: 0.5)
        reader.finishCardViewportTransition(completed: true)
        XCTAssertEqual(text.alpha, 1, "Text stays live throughout the transition")
    }

    @MainActor
    func testInteractiveWidthPreservesLinesWithoutWordSeparators() throws {
        var item = SavedItem(urlString: "https://example.com/stable-cjk")
        item.state = .ready
        let reader = ScrollReaderViewController(item: item, content: ArticleContent(
            title: "Reading", blocks: [paragraph(String(repeating: "既存の行は幅を保ち新しい行だけが変化します。", count: 200))]))
        reader.view.frame = CGRect(x: 0, y: 0, width: 350, height: 600)
        reader.view.layoutIfNeeded()
        let text = try XCTUnwrap(firstTextView(in: reader.view))
        text.contentOffset.y = 650
        reader.scrollViewDidScroll(text)
        let probe = CGPoint(x: 10, y: text.contentOffset.y + 150)
        let glyph = text.layoutManager.glyphIndex(for: probe, in: text.textContainer)
        var before = NSRange()
        let source = text.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &before)
        let characters = text.layoutManager.characterRange(forGlyphRange: before, actualGlyphRange: nil)
        reader.prepareForCardViewportTransition(
            to: CGSize(width: 600, height: 600), preservingVisibleLines: true)
        reader.view.frame.size.width = 600
        reader.view.layoutIfNeeded()
        reader.finishCardViewportTransition(completed: true)
        let destinationGlyphs = text.layoutManager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        var after = NSRange()
        let destination = text.layoutManager.lineFragmentRect(
            forGlyphAt: destinationGlyphs.location, effectiveRange: &after)
        XCTAssertEqual(text.layoutManager.characterRange(forGlyphRange: after, actualGlyphRange: nil), characters)
        XCTAssertEqual(destination.width, source.width, accuracy: 0.5)
    }

    @MainActor
    func testInteractiveReflowKeepsQuoteAndListIndents() throws {
        for kind in [ArticleContent.Block.Kind.quote, .listItem] {
            let content = ArticleContent(title: "Indented", blocks: [.init(
                kind: kind, text: String(repeating: "Indented words keep their proper place in the paragraph. ", count: 150), links: [])])
            let item = SavedItem(urlString: "https://example.com/indents")
            let reader = ScrollReaderViewController(item: item, content: content, includesArticleTitle: false)
            reader.view.frame = CGRect(x: 0, y: 0, width: 350, height: 600)
            reader.view.layoutIfNeeded()
            let text = try XCTUnwrap(firstTextView(in: reader.view))
            text.contentOffset.y = 500
            reader.scrollViewDidScroll(text)
            reader.prepareForCardViewportTransition(to: CGSize(width: 600, height: 600), preservingVisibleLines: true)
            reader.view.frame.size.width = 600
            reader.view.layoutIfNeeded()
            reader.finishCardViewportTransition(completed: true)
            text.contentOffset.y += 900
            reader.scrollViewDidScroll(text)
            let manager = text.layoutManager
            let glyph = manager.glyphIndex(for: CGPoint(x: 50, y: text.contentOffset.y + 100), in: text.textContainer)
            let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let control = ScrollReaderViewController(item: item, content: content, includesArticleTitle: false)
            control.view.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
            control.view.layoutIfNeeded()
            let wide = try XCTUnwrap(firstTextView(in: control.view))
            wide.layoutManager.ensureLayout(for: wide.textContainer)
            let expected = wide.layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            XCTAssertEqual(fragment.minX, expected.minX, accuracy: 0.5)
            XCTAssertEqual(fragment.width, expected.width, accuracy: 0.5)
        }
    }

    @MainActor
    func testLiveResizeKeepsTheSamePassageAtTheSameHeight() throws {
        var item = SavedItem(urlString: "https://example.com/resize")
        item.state = .ready
        let content = ArticleContent(title: "Resize", blocks: [
            paragraph(String(repeating: "A changing window should keep this passage in place. ", count: 200))])
        let reader = ScrollReaderViewController(item: item, content: content)
        reader.view.frame = CGRect(x: 0, y: 0, width: 350, height: 750)
        reader.view.layoutIfNeeded()
        let text = try XCTUnwrap(firstTextView(in: reader.view))
        text.layoutManager.ensureLayout(for: text.textContainer)
        text.contentOffset.y = 600
        reader.scrollViewDidScroll(text)
        let glyph = text.layoutManager.glyphIndex(for: CGPoint(
            x: 1, y: text.contentOffset.y + text.bounds.height * 0.25 - text.textContainerInset.top),
            in: text.textContainer)
        let character = text.layoutManager.characterIndexForGlyph(at: glyph)
        func screenY() -> CGFloat {
            let range = text.layoutManager.glyphRange(
                forCharacterRange: NSRange(location: character, length: 1), actualCharacterRange: nil)
            return text.layoutManager.boundingRect(forGlyphRange: range, in: text.textContainer).minY
                + text.textContainerInset.top - text.contentOffset.y
        }
        let before = screenY()
        reader.prepareForCardViewportTransition(to: CGSize(width: 600, height: 750), preservingVisibleLines: true)
        reader.view.frame.size.width = 600
        reader.view.layoutIfNeeded()
        reader.finishCardViewportTransition(completed: true)
        XCTAssertEqual(text.bounds.width, 600, accuracy: 0.5)
        reader.view.frame.size.width = 900
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
        XCTAssertEqual(screenY(), before, accuracy: 2)
        XCTAssertGreaterThan(text.bounds.width - text.textContainerInset.left - text.textContainerInset.right, 600)
    }

    @MainActor
    func testLiveResizeKeepsTheTitleAtTheTop() throws {
        let reader = ScrollReaderViewController(
            item: SavedItem(urlString: "https://example.com/title-resize"),
            content: ArticleContent(title: "Title", blocks: [
                paragraph(String(repeating: "A preview should retain its title. ", count: 80))]))
        reader.topChromeInset = 96
        reader.view.frame = CGRect(x: 0, y: 0, width: 834, height: 900)
        reader.view.layoutIfNeeded()
        let text = try XCTUnwrap(firstTextView(in: reader.view))
        XCTAssertEqual(text.contentOffset.y, -text.adjustedContentInset.top, accuracy: 0.5)
        reader.view.frame.size = CGSize(width: 260, height: 400)
        reader.topChromeInset = 140
        reader.view.layoutIfNeeded()
        XCTAssertEqual(text.contentOffset.y, -text.adjustedContentInset.top, accuracy: 0.5)
    }

    private func firstTextView(in view: UIView) -> UITextView? {
        if let tv = view as? UITextView { return tv }
        for sub in view.subviews { if let found = firstTextView(in: sub) { return found } }
        return nil
    }

    private func makeTinyPNG() throws -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return try XCTUnwrap(image.pngData())
    }
}
