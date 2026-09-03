//
//  WriterHTMLRendererTests.swift
//  LunaTests
//

import XCTest
import LunaWriterText

/// Pins the export renderer. It reads the same scan the editor styles, so a
/// block the editor shows as a table must leave here as a table, and text
/// that could be read as markup must arrive escaped.
final class WriterHTMLRendererTests: XCTestCase {

    private func html(_ markdown: String, options: MarkdownHTMLRenderer.Options = .init(includeDocumentShell: false)) -> String {
        MarkdownHTMLRenderer(options: options).render(markdown: markdown as NSString)
    }

    private func assertContains(_ haystack: String, _ needle: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(haystack.contains(needle), "missing \(needle) in:\n\(haystack)", file: file, line: line)
    }

    // MARK: - Blocks

    func testHeadingsCarryTheirLevel() {
        assertContains(html("# One\n"), "<h1>One</h1>")
        assertContains(html("###### Six\n"), "<h6>Six</h6>")
    }

    func testParagraphLinesJoinAndAHardBreakBecomesABreakTag() {
        assertContains(html("one\ntwo\n"), "<p>one\ntwo</p>")
        assertContains(html("one  \ntwo\n"), "<br>")
    }

    func testNestedListsCloseInTheRightOrder() {
        let out = html("- one\n- two\n  - deep\n- three\n")
        assertContains(out, "<li>two<ul>\n<li>deep</li>\n</ul>\n</li>")
        XCTAssertEqual(out.components(separatedBy: "<ul>").count - 1, 2)
        XCTAssertEqual(out.components(separatedBy: "</ul>").count - 1, 2)
    }

    func testOrderedAndTaskListsRenderTheirOwnMarkup() {
        assertContains(html("1. one\n2. two\n"), "<ol>")
        assertContains(html("- [x] done\n"), "<input type=\"checkbox\" disabled checked>")
        assertContains(html("- [ ] open\n"), "<input type=\"checkbox\" disabled>")
    }

    func testBlockquoteNestsByDepthAndClosesOnABlankLine() {
        let out = html("> one\n> > deeper\n\nafter\n")
        assertContains(out, "<blockquote>")
        XCTAssertEqual(out.components(separatedBy: "</blockquote>").count - 1, 2)
        assertContains(out, "<p>after</p>")
    }

    func testFencedCodeKeepsItsLanguageAndEscapesItsBody() {
        let out = html("```swift\nlet a = 1 < 2 && \"x\"\n```\n")
        assertContains(out, "<pre><code class=\"language-swift\">")
        assertContains(out, "let a = 1 &lt; 2 &amp;&amp; &quot;x&quot;")
        XCTAssertFalse(out.contains("<em>"))
    }

    func testMarkdownInsideAFenceIsNotRendered() {
        let out = html("```\n# not a heading *not em*\n```\n")
        XCTAssertFalse(out.contains("<h1>"))
        XCTAssertFalse(out.contains("<em>"))
    }

    func testThematicBreakBecomesARule() {
        assertContains(html("a\n\n---\n\nb\n"), "<hr>")
    }

    func testTableSplitsHeaderFromBodyAndKeepsAlignment() {
        let out = html("| Name | Qty |\n| :--- | ---: |\n| Apples | 3 |\n")
        assertContains(out, "<thead>")
        assertContains(out, "<th style=\"text-align: left\">Name</th>")
        assertContains(out, "<th style=\"text-align: right\">Qty</th>")
        assertContains(out, "<td style=\"text-align: left\">Apples</td>")
        XCTAssertEqual(out.components(separatedBy: "<td").count - 1, 2)
    }

    // MARK: - Inline

    func testInlineSpansBecomeTheirTags() {
        let out = html("a *em* b **st** c ~~cut~~ d ==hot== e `code`\n")
        assertContains(out, "<em>em</em>")
        assertContains(out, "<strong>st</strong>")
        assertContains(out, "<del>cut</del>")
        assertContains(out, "<mark>hot</mark>")
        assertContains(out, "<code>code</code>")
    }

    func testNestedEmphasisNests() {
        assertContains(html("***both***\n"), "<strong><em>both</em></strong>")
    }

    func testLinksAndImagesCarryTheirTarget() {
        assertContains(html("[label](https://a.example/x)\n"), "<a href=\"https://a.example/x\">label</a>")
        assertContains(html("![alt text](pic.png)\n"), "<img src=\"pic.png\" alt=\"alt text\">")
        assertContains(html("<https://a.example>\n"), "<a href=\"https://a.example\">https://a.example</a>")
        assertContains(html("www.a.example here\n"), "<a href=\"https://www.a.example\">www.a.example</a>")
    }

    func testRelativeImagePathsResolveAgainstTheGivenBase() {
        let options = MarkdownHTMLRenderer.Options(
            includeDocumentShell: false,
            imageBaseURL: URL(string: "file:///Library/Sheets/"))
        assertContains(html("![a](pic.png)\n", options: options), "src=\"file:///Library/Sheets/pic.png\"")
    }

    func testFootnoteReferenceLinksToItsDefinition() {
        let out = html("body[^a] here.\n\n[^a]: the **note**.\n")
        assertContains(out, "<a href=\"#fn-a\">a</a>")
        assertContains(out, "<li id=\"fn-a\">the <strong>note</strong>.</li>")
        assertContains(out, "<section class=\"footnotes\">")
    }

    // MARK: - Escaping and the shell

    func testTextThatLooksLikeMarkupIsEscaped() {
        let out = html("5 < 6 & 7 > 3 in <b>text</b>\n")
        assertContains(out, "5 &lt; 6 &amp; 7 &gt; 3")
        XCTAssertFalse(out.contains("<b>"))
    }

    func testBackslashEscapesLeaveTheDocument() {
        let out = html("\\*not emphasis\\*\n")
        assertContains(out, "*not emphasis*")
        XCTAssertFalse(out.contains("<em>"))
        XCTAssertFalse(out.contains("\\"))
    }

    func testShellIsOptionalAndCarriesTheTitle() {
        let bare = html("# One\n")
        XCTAssertFalse(bare.contains("<html>"))
        let full = html("# One\n", options: .init(includeDocumentShell: true, title: "My & Sheet", stylesheet: "p{color:red}"))
        assertContains(full, "<!DOCTYPE html>")
        assertContains(full, "<title>My &amp; Sheet</title>")
        assertContains(full, "<style>p{color:red}</style>")
    }
}
