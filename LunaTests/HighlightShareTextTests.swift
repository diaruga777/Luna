//
//  HighlightShareTextTests.swift
//  LunaTests
//
//  Covers ScrollReaderViewController.makeHighlightShareText — the pure formatter
//  behind the reader's "highlight and share" text-selection action (which Copy
//  goes through too, via QuotingTextView) — and the pure rule deciding when a
//  sentence long-press expands the selection immediately.
//

import LunaReaderUI
import LunaModels
import UIKit
import XCTest

final class HighlightShareTextTests: XCTestCase {

    /// A real web URL (isShareable == true) → the quote in literal double-quotes,
    /// a blank line, then the URL.
    func testShareableItemWrapsQuoteAndAppendsURL() {
        let item = ReadingListItem(
            seed: "share-web",
            urlString: "https://example.com/article",
            title: "Example",
            dateAdded: Date())
        XCTAssertTrue(item.isShareable)

        let text = ScrollReaderViewController.makeHighlightShareText(
            quote: "  A memorable line.  ", item: item)

        XCTAssertEqual(text, "\"A memorable line.\"\n\nhttps://example.com/article")
    }

    /// A non-web / synthetic-scheme item (isShareable == false) → the bare trimmed
    /// quote with no surrounding quotation marks and no URL.
    func testNonShareableItemSharesBareTrimmedQuote() {
        let item = ReadingListItem(
            seed: "share-doc",
            urlString: "lunadoc://imported/report",
            title: "Imported",
            dateAdded: Date())
        XCTAssertFalse(item.isShareable)

        let text = ScrollReaderViewController.makeHighlightShareText(
            quote: "\n  Just the words.  \n", item: item)

        XCTAssertEqual(text, "Just the words.")
    }

    /// An empty urlString is also not shareable → bare quote.
    func testEmptyURLStringSharesBareQuote() {
        let item = ReadingListItem(
            seed: "share-empty",
            urlString: "",
            title: nil,
            dateAdded: Date())
        XCTAssertFalse(item.isShareable)

        let text = ScrollReaderViewController.makeHighlightShareText(
            quote: "Bare.", item: item)

        XCTAssertEqual(text, "Bare.")
    }

    // MARK: - Copy goes through the same formatter

    /// A selected passage's Copy is handed to the reader, which formats it exactly
    /// as Share does. UIKit's plain-text copy is NOT what runs.
    func testCopyWithASelectionAsksTheReaderForTheQuote() {
        let textView = QuotingTextView(usingTextLayoutManager: false)
        textView.text = "One sentence. Another one."
        textView.selectedRange = NSRange(location: 0, length: 13)
        var asked: [NSRange] = []
        textView.copySelectionAsQuote = { range in
            asked.append(range)
            return true
        }

        textView.copy(nil)

        XCTAssertEqual(asked, [NSRange(location: 0, length: 13)])
    }

    /// With nothing selected there is no quote to make, so the copy falls straight
    /// through to UIKit.
    func testCopyWithoutASelectionFallsThroughToTheSystem() {
        let textView = QuotingTextView(usingTextLayoutManager: false)
        textView.text = "One sentence."
        textView.selectedRange = NSRange(location: 4, length: 0)
        var asked = false
        textView.copySelectionAsQuote = { _ in
            asked = true
            return true
        }

        textView.copy(nil)

        XCTAssertFalse(asked)
    }

    // MARK: - When the long press expands the selection itself

    /// The ordinary order: the press lands before the text view has selected
    /// anything, so the NEXT selection change is the one to snap.
    func testLongPressWithNoSelectionArmsTheNextChange() {
        XCTAssertEqual(
            ScrollReaderViewController.sentenceLongPressAction(
                caret: 12, selection: NSRange(location: 12, length: 0)),
            .armNextSelectionChange)
    }

    /// The card order: the word under the finger is ALREADY selected by the time
    /// the press fires, so it expands immediately — waiting would wait forever.
    func testLongPressOverAnAlreadySelectedWordExpandsImmediately() {
        XCTAssertEqual(
            ScrollReaderViewController.sentenceLongPressAction(
                caret: 6, selection: NSRange(location: 4, length: 8)),
            .expandNow(caret: 6))
    }

    /// A press on a word's trailing half resolves to the position AFTER its last
    /// glyph, which is still that word's selection.
    func testLongPressAtTheSelectionsEndBoundaryExpandsImmediately() {
        XCTAssertEqual(
            ScrollReaderViewController.sentenceLongPressAction(
                caret: 12, selection: NSRange(location: 4, length: 8)),
            .expandNow(caret: 12))
    }

    /// A selection left over from an earlier press elsewhere in the article is not
    /// this press's, so it is left alone.
    func testLongPressAwayFromAStaleSelectionArmsTheNextChange() {
        XCTAssertEqual(
            ScrollReaderViewController.sentenceLongPressAction(
                caret: 400, selection: NSRange(location: 4, length: 8)),
            .armNextSelectionChange)
    }

    /// Empty text has no caret at all.
    func testLongPressWithNoCaretArmsTheNextChange() {
        XCTAssertEqual(
            ScrollReaderViewController.sentenceLongPressAction(
                caret: nil, selection: NSRange(location: 0, length: 0)),
            .armNextSelectionChange)
    }
}
