//
//  MarkdownFormatStyleTests.swift
//  LunaWriterTests
//

import XCTest
@testable import LunaWriterText

final class MarkdownFormatStyleTests: XCTestCase {

    /// The text and caret after the style is applied at `caret`, as one
    /// string with "|" at the caret.
    private func apply(_ style: MarkdownFormatStyle, to text: String, at caret: Int) -> String {
        let mutable = NSMutableString(string: text)
        let application = style.application(at: caret, in: mutable)
        MarkdownEditingCommands.apply(application.edits, to: mutable)
        mutable.insert("|", at: application.caret)
        return mutable as String
    }

    func testAnInlineStyleOpensAnEmptyPairWithTheCaretInside() {
        XCTAssertEqual(apply(.bold, to: "hello ", at: 6), "hello **|**")
        XCTAssertEqual(apply(.italic, to: "", at: 0), "*|*")
        XCTAssertEqual(apply(.strikethrough, to: "a b", at: 1), "a~~|~~ b")
        XCTAssertEqual(apply(.underline, to: "", at: 0), "<u>|</u>")
        XCTAssertEqual(apply(.link, to: "", at: 0), "[|]()")
        XCTAssertEqual(apply(.image, to: "", at: 0), "![|]()")
        XCTAssertEqual(apply(.inlineCode, to: "", at: 0), "`|`")
    }

    func testAHeadingMarksTheCaretsParagraphAndMovesTheCaretWithIt() {
        XCTAssertEqual(apply(.heading2, to: "Title ", at: 6), "## Title |")
        XCTAssertEqual(apply(.heading1, to: "## Title", at: 8), "# Title|")
        XCTAssertEqual(apply(.heading3, to: "a\nb", at: 3), "a\n### b|")
        XCTAssertEqual(apply(.heading1, to: "", at: 0), "# |")
    }

    func testAListOrQuoteReplacesTheLinesExistingMarker() {
        XCTAssertEqual(apply(.bulletList, to: "", at: 0), "- |")
        XCTAssertEqual(apply(.bulletList, to: "item", at: 4), "- item|")
        XCTAssertEqual(apply(.numberedList, to: "- item", at: 6), "1. item|")
        XCTAssertEqual(apply(.taskList, to: "1. item", at: 7), "- [ ] item|")
        XCTAssertEqual(apply(.quote, to: "- [ ] item", at: 10), "> item|")
        XCTAssertEqual(apply(.bulletList, to: "  > deep", at: 8), "  - deep|")
        XCTAssertEqual(apply(.quote, to: "> same", at: 6), "> same|", "already there: nothing changes")
    }

    func testABlockStyleStandsOnItsOwnLines() {
        XCTAssertEqual(apply(.codeBlock, to: "", at: 0), "```\n|\n```")
        XCTAssertEqual(apply(.codeBlock, to: "before", at: 6), "before\n```\n|\n```")
        XCTAssertEqual(apply(.codeBlock, to: "a\nb", at: 2), "a\n```\n|\n```\nb")
        XCTAssertEqual(apply(.divider, to: "para", at: 4), "para\n---\n|")
        XCTAssertEqual(apply(.divider, to: "", at: 0), "---\n|")
    }

    func testThePreviewShowsTheMarksAroundASample() {
        XCTAssertEqual(MarkdownFormatStyle.bold.preview(sample: "text"), "**text**")
        XCTAssertEqual(MarkdownFormatStyle.heading2.preview(sample: "text"), "## text")
        XCTAssertEqual(MarkdownFormatStyle.link.preview(sample: "text"), "[text]()")
        XCTAssertEqual(MarkdownFormatStyle.divider.preview(sample: "text"), "---")
        XCTAssertEqual(MarkdownFormatStyle.codeBlock.preview(sample: "text"), "```\ntext\n```")
    }
}
