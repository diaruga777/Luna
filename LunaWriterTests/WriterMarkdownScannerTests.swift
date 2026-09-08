//
//  WriterMarkdownScannerTests.swift
//  LunaWriterTests
//

import XCTest
import LunaWriterText

/// Pins what `MarkdownScanner` says about a line: which block it is, which
/// characters are markup the editor greys out, and what it leaves for the
/// next line. The editor styles from these answers, so a wrong block kind is
/// a wrong font and a wrong markup range is visible syntax.
final class WriterMarkdownScannerTests: XCTestCase {

    private func scan(_ markdown: String, state: ScanState = .initial) -> [LineScan] {
        let text = markdown as NSString
        var out: [LineScan] = []
        var current = state
        var location = 0
        while location < text.length {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            let line = MarkdownScanner.scanLine(in: text, lineRange: lineRange, state: current)
            out.append(line)
            current = line.stateAfter
            location = lineRange.location + lineRange.length
        }
        return out
    }

    private func text(_ markdown: String, _ range: NSRange) -> String {
        (markdown as NSString).substring(with: range)
    }

    private func fence(_ marker: Character, width: Int) -> ScanState.FenceMarker {
        ScanState.FenceMarker(marker: marker.utf16.first!, width: width)
    }

    // MARK: - Blocks

    func testHeadingReportsLevelAndLeavesHashesAsMarkup() {
        let source = "### Deep heading\n"
        let line = scan(source)[0]
        XCTAssertEqual(line.block.kind, .heading(level: 3))
        XCTAssertEqual(line.block.markupRanges.map { text(source, $0) }, ["###"])
        XCTAssertEqual(text(source, line.block.contentRange), "Deep heading")
    }

    func testClosingHashesAreMarkupAndNotContent() {
        let source = "## Middle ##\n"
        let line = scan(source)[0]
        XCTAssertEqual(text(source, line.block.contentRange), "Middle")
        XCTAssertEqual(line.block.markupRanges.map { text(source, $0) }, ["##", "##"])
    }

    func testSevenHashesIsAParagraph() {
        XCTAssertEqual(scan("####### not a heading\n")[0].block.kind, .paragraph)
    }

    func testHashWithoutASpaceIsAParagraph() {
        XCTAssertEqual(scan("#hashtag\n")[0].block.kind, .paragraph)
    }

    func testListItemCarriesOrderIndentAndTask() {
        let source = "  - [x] done\n"
        let line = scan(source)[0]
        XCTAssertEqual(line.block.kind, .listItem(ordered: false, indent: 2, task: .checked))
        XCTAssertEqual(text(source, line.block.contentRange), "done")
        XCTAssertEqual(line.block.markupRanges.map { text(source, $0) }, ["- ", "[x] "])
    }

    func testOrderedListAcceptsBothDelimiters() {
        XCTAssertEqual(scan("1. one\n")[0].block.kind, .listItem(ordered: true, indent: 0, task: nil))
        XCTAssertEqual(scan("2) two\n")[0].block.kind, .listItem(ordered: true, indent: 0, task: nil))
        XCTAssertEqual(scan("1.no space\n")[0].block.kind, .paragraph)
    }

    func testEmphasisAtLineStartIsNotABullet() {
        XCTAssertEqual(scan("*emphasised* opening\n")[0].block.kind, .paragraph)
    }

    func testThreeMarksAreAThematicBreakAndOneIsAListItem() {
        XCTAssertEqual(scan("***\n")[0].block.kind, .thematicBreak)
        XCTAssertEqual(scan("- - -\n")[0].block.kind, .thematicBreak)
        XCTAssertEqual(scan("-\n")[0].block.kind, .listItem(ordered: false, indent: 0, task: nil))
    }

    func testBlockquoteCountsItsDepth() {
        let source = "> > deep\n"
        let line = scan(source)[0]
        XCTAssertEqual(line.block.kind, .blockquote(depth: 2))
        XCTAssertEqual(text(source, line.block.contentRange), "deep")
    }

    func testFootnoteDefinitionKeepsItsLabel() {
        let source = "[^note]: the body\n"
        let line = scan(source)[0]
        XCTAssertEqual(line.block.kind, .footnoteDefinition(label: "note"))
        XCTAssertEqual(text(source, line.block.contentRange), "the body")
    }

    // MARK: - State that crosses lines

    func testFenceSwallowsMarkdownUntilItCloses() {
        let lines = scan("```swift\n# not a heading\n```\n# a heading\n")
        XCTAssertEqual(lines[0].block.kind, .fenceDelimiter)
        XCTAssertEqual(lines[0].stateAfter.inFence, fence("`", width: 3))
        XCTAssertEqual(lines[1].block.kind, .fencedCode(language: "swift"))
        XCTAssertEqual(lines[2].block.kind, .fenceDelimiter)
        XCTAssertNil(lines[2].stateAfter.inFence)
        XCTAssertEqual(lines[3].block.kind, .heading(level: 1))
    }

    func testATildeFenceIsNotClosedByBackticks() {
        let lines = scan("~~~\n```\nstill code\n")
        XCTAssertEqual(lines[1].block.kind, .fencedCode(language: nil))
        XCTAssertEqual(lines[2].block.kind, .fencedCode(language: nil))
        XCTAssertEqual(lines[2].stateAfter.inFence, fence("~", width: 3))
    }

    func testFencedCodeLineCarriesTheOpeningLanguage() {
        let lines = scan("```python\nprint(1)\n")
        XCTAssertEqual(lines[1].block.kind, .fencedCode(language: "python"))
    }

    func testFencedCodeLineKeepsItsLeadingIndentation() {
        let source = "```\n    indented\n```\n"
        let lines = scan(source)
        XCTAssertEqual(text(source, lines[1].block.contentRange), "    indented")
    }

    func testDelimiterRowTurnsTheHeaderRowIntoATable() {
        let lines = scan("| a | b |\n| --- | :-: |\n| 1 | 2 |\n\nplain | pipe\n")
        XCTAssertEqual(lines[0].block.kind, .tableRow(isHeader: true))
        XCTAssertEqual(lines[1].block.kind, .tableDelimiter)
        XCTAssertEqual(lines[2].block.kind, .tableRow(isHeader: false))
        XCTAssertTrue(lines[2].stateAfter.inTable)
        XCTAssertEqual(lines[3].block.kind, .blank)
        XCTAssertFalse(lines[3].stateAfter.inTable)
        XCTAssertEqual(lines[4].block.kind, .tableRow(isHeader: true))
    }

    // MARK: - Inline spans

    private func inlineKinds(_ source: String) -> [InlineKind] {
        scan(source)[0].inlines.map { $0.kind }
    }

    func testInlineSpansAreFoundWithTheirMarkup() {
        let source = "a *em* b **st** c ~~cut~~ d ==hot== e `code`\n"
        let line = scan(source)[0]
        XCTAssertEqual(line.inlines.map { $0.kind },
                       [.emphasis, .strong, .strikethrough, .highlight, .code])
        XCTAssertEqual(line.inlines.map { text(source, $0.contentRange) },
                       ["em", "st", "cut", "hot", "code"])
        XCTAssertEqual(line.inlines[0].markupRanges.map { text(source, $0) }, ["*", "*"])
    }

    func testCodeSpanHidesMarkdownInsideIt() {
        XCTAssertEqual(inlineKinds("`a *b* c`\n"), [.code])
    }

    func testEscapedMarkerDoesNotOpenASpan() {
        XCTAssertEqual(inlineKinds("\\*not emphasis*\n"), [])
    }

    func testUnderscoreInsideAWordIsNotEmphasis() {
        XCTAssertEqual(inlineKinds("snake_case_name here\n"), [])
        XCTAssertEqual(inlineKinds("_real_ emphasis\n"), [.emphasis])
    }

    func testEmphasisNeedsContentAfterTheMarker() {
        XCTAssertEqual(inlineKinds("a * b * c\n"), [])
    }

    func testTripleMarkerNestsStrongAndEmphasis() {
        let source = "***both***\n"
        let line = scan(source)[0]
        XCTAssertEqual(line.inlines.map { $0.kind }, [.strong, .emphasis])
        XCTAssertEqual(text(source, line.inlines[1].contentRange), "both")
        XCTAssertEqual(line.inlines[0].range, NSRange(location: 0, length: 10))
    }

    func testLinkAndImageKeepTheirDestination() {
        let source = "[label](https://a.example/x) and ![alt](pic.png)\n"
        let line = scan(source)[0]
        XCTAssertEqual(line.inlines.map { $0.kind },
                       [.link(destination: "https://a.example/x"), .image(destination: "pic.png")])
        XCTAssertEqual(text(source, line.inlines[0].contentRange), "label")
    }

    func testReferenceLinkUsesItsLabelAsDestination() {
        XCTAssertEqual(inlineKinds("[text][ref] here\n"), [.link(destination: "ref")])
    }

    func testLinkTextIsScannedForItsOwnSpans() {
        let source = "[a **b**](x.md)\n"
        let line = scan(source)[0]
        XCTAssertEqual(line.inlines.map { $0.kind }, [.link(destination: "x.md"), .strong])
    }

    func testAngleAndBareAutolinksAreBothFound() {
        XCTAssertEqual(inlineKinds("<https://a.example> and https://b.example/p\n"), [.autolink, .autolink])
        XCTAssertEqual(inlineKinds("<not a link>\n"), [])
    }

    func testFootnoteReferenceKeepsItsLabel() {
        XCTAssertEqual(inlineKinds("body[^42].\n"), [.footnoteReference(label: "42")])
    }

    func testTwoTrailingSpacesAreAHardBreak() {
        let source = "line one  \nline two\n"
        let lines = scan(source)
        XCTAssertEqual(lines[0].inlines.map { $0.kind }, [.hardBreak])
        XCTAssertEqual(lines[1].inlines.count, 0)
    }

    func testBackslashAtTheEndOfALineIsAHardBreak() {
        XCTAssertEqual(inlineKinds("line one\\\n"), [.hardBreak])
    }

    // MARK: - Ranges

    func testLineRangesTileTheDocumentIncludingTerminators() {
        let source = "one\r\ntwo\nthree"
        let lines = scan(source)
        XCTAssertEqual(lines.map { $0.block.lineRange.length }, [5, 4, 5])
        var expected = 0
        for line in lines {
            XCTAssertEqual(line.block.lineRange.location, expected)
            expected += line.block.lineRange.length
        }
        XCTAssertEqual(expected, (source as NSString).length)
    }
}
