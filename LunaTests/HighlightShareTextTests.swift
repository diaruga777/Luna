//
//  HighlightShareTextTests.swift
//  LunaTests
//
//  Covers ScrollReaderViewController.makeHighlightShareText — the pure formatter
//  behind the reader's "highlight and share" text-selection action.
//

import LunaReaderUI
import LunaModels
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
}
