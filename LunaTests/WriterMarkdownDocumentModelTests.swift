//
//  WriterMarkdownDocumentModelTests.swift
//  LunaTests
//

import XCTest
import LunaWriterText

/// Pins the incremental model the editor keeps in step with its text storage.
/// The load-bearing claim is that an edit costs the lines it touches: the
/// model must agree with a full rescan after any sequence of edits, and must
/// report a changed range no larger than the change really is.
final class WriterMarkdownDocumentModelTests: XCTestCase {

    private func fullScan(of text: NSString) -> [LineScan] {
        MarkdownDocumentModel(text: text).allLineScans()
    }

    // MARK: - Line table

    func testLineIndexAndRangeCoverEveryOffset() {
        let model = MarkdownDocumentModel(text: "one\r\ntwo\nthree")
        XCTAssertEqual(model.lineCount, 3)
        XCTAssertEqual(model.lineIndex(at: 0), 0)
        XCTAssertEqual(model.lineIndex(at: 4), 0)
        XCTAssertEqual(model.lineIndex(at: 5), 1)
        XCTAssertEqual(model.lineIndex(at: 9), 2)
        XCTAssertEqual(model.lineIndex(at: 14), 2)
        XCTAssertEqual(model.lineRange(at: 1), NSRange(location: 5, length: 4))
    }

    func testEmptyDocumentStillHasOneBlankLine() {
        let model = MarkdownDocumentModel(text: "")
        XCTAssertEqual(model.lineCount, 1)
        XCTAssertEqual(model.block(at: 0).kind, .blank)
    }

    func testTypingAcrossALineBreakSplitsAndJoinsLines() {
        let model = MarkdownDocumentModel(text: "one two\n")
        model.replaceCharacters(in: NSRange(location: 3, length: 1), with: "\n")
        XCTAssertEqual(model.lineCount, 2)
        XCTAssertEqual(model.text, "one\ntwo\n" as NSString)
        model.replaceCharacters(in: NSRange(location: 3, length: 1), with: " ")
        XCTAssertEqual(model.lineCount, 1)
        XCTAssertEqual(model.allLineScans(), fullScan(of: "one two\n"))
    }

    // MARK: - Incremental rescan

    func testEditRescansOnlyTheLineItTouches() {
        var source = ""
        for index in 0..<200 { source += "paragraph \(index)\n" }
        let model = MarkdownDocumentModel(text: source)
        let target = (source as NSString).range(of: "paragraph 100")
        let changed = model.replaceCharacters(in: NSRange(location: target.location, length: 0), with: "# ")
        XCTAssertEqual(model.lineIndex(at: changed.location), 100)
        XCTAssertEqual(changed.length, "# paragraph 100\n".utf16.count)
        XCTAssertEqual(model.block(at: target.location).kind, .heading(level: 1))
    }

    func testOpeningAFenceRestylesEveryLineItSwallows() {
        let source = "alpha\n# beta\ngamma\n"
        let model = MarkdownDocumentModel(text: source)
        XCTAssertEqual(model.block(at: (source as NSString).range(of: "# beta").location).kind, .heading(level: 1))

        let changed = model.replaceCharacters(in: NSRange(location: 0, length: 0), with: "```\n")
        XCTAssertEqual(changed, NSRange(location: 0, length: model.text.length))
        XCTAssertEqual(model.block(at: (model.text as NSString).range(of: "# beta").location).kind,
                       .fencedCode(language: nil))
        XCTAssertEqual(model.allLineScans(), fullScan(of: model.text))
    }

    func testAPastedFenceThatClosesItselfLeavesTheRestAlone() {
        let source = "para\n```\ncode\n```\ntail\n"
        let model = MarkdownDocumentModel(text: source)
        let changed = model.replaceCharacters(in: NSRange(location: 0, length: 0), with: "```\nx\n```\n")
        let codeStart = (model.text as NSString).range(of: "code").location
        XCTAssertLessThan(changed.location + changed.length, codeStart)
        XCTAssertEqual(model.block(at: codeStart).kind, .fencedCode(language: nil))
        XCTAssertEqual(model.allLineScans(), fullScan(of: model.text))
    }

    func testClosingAFenceRestylesTheLinesItReleases() {
        let source = "```\none\ntwo\nthree\n"
        let model = MarkdownDocumentModel(text: source)
        XCTAssertEqual(model.block(at: (source as NSString).range(of: "two").location).kind,
                       .fencedCode(language: nil))
        model.replaceCharacters(in: NSRange(location: 0, length: 3), with: "")
        XCTAssertEqual(model.block(at: (model.text as NSString).range(of: "two").location).kind, .paragraph)
        XCTAssertEqual(model.allLineScans(), fullScan(of: model.text))
    }

    func testIncrementalModelMatchesAFullRescanAfterManyRandomEdits() {
        let fragments = ["# Head\n", "text *em* and **strong**\n", "\n", "```swift\n", "```\n", "- item\n",
                         "> quote\n", "| a | b |\n", "| --- | --- |\n", "1. one\n", "`code` line\n",
                         "~~~\n", "---\n", "[^n]: note\n", "a", "*", "`", "\r\n"]
        var random = SplitMix64(seed: 0x5DEECE66D)

        var seed = ""
        for _ in 0..<60 { seed += fragments[random.next(fragments.count)] }
        let model = MarkdownDocumentModel(text: seed)
        let mirror = NSMutableString(string: seed)

        for step in 0..<500 {
            let location = random.next(mirror.length + 1)
            let deleted = min(random.next(9), mirror.length - location)
            let inserted = random.next(4) == 0 ? "" : fragments[random.next(fragments.count)]
            let edit = NSRange(location: location, length: deleted)
            mirror.replaceCharacters(in: edit, with: inserted)
            model.replaceCharacters(in: edit, with: inserted)

            if step % 25 == 0 || step == 499 {
                XCTAssertEqual(model.text, mirror as NSString, "text drifted at step \(step)")
                XCTAssertEqual(model.allLineScans(), fullScan(of: mirror as NSString), "scan drifted at step \(step)")
            }
        }
    }

    // MARK: - Reading

    func testBlocksTileTheRangeTheyAreAskedFor() {
        let source = "# One\n\ntwo\n- three\n"
        let model = MarkdownDocumentModel(text: source)
        let blocks = model.blocks(in: NSRange(location: 0, length: (source as NSString).length))
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks.map { $0.lineRange.location }, [0, 6, 7, 11])
    }

    func testHeadingsGiveTheOutlineWithMarkupRemoved() {
        let model = MarkdownDocumentModel(text: "# One **bold**\nbody\n## Two `code`\n")
        XCTAssertEqual(model.headings().map { $0.level }, [1, 2])
        XCTAssertEqual(model.headings().map { $0.text }, ["One bold", "Two code"])
        XCTAssertEqual(model.firstHeadingText(), "One bold")
    }

    func testHeadingInsideAFenceIsNotInTheOutline() {
        let model = MarkdownDocumentModel(text: "```\n# not a heading\n```\n# real\n")
        XCTAssertEqual(model.headings().map { $0.text }, ["real"])
    }

    func testParagraphRangeJoinsPlainLinesAndStopsAtOtherBlocks() {
        let source = "# Head\nfirst line\nsecond line\n\nafter\n"
        let model = MarkdownDocumentModel(text: source)
        let inside = (source as NSString).range(of: "second").location
        let paragraph = model.paragraphRange(containing: inside)
        XCTAssertEqual((source as NSString).substring(with: paragraph), "first line\nsecond line\n")
        let heading = model.paragraphRange(containing: 2)
        XCTAssertEqual((source as NSString).substring(with: heading), "# Head\n")
    }

    func testSharedTextModelFollowsAnEditMadeByItsOwner() {
        let storage = NSMutableString(string: "plain line\n")
        let model = MarkdownDocumentModel(sharedText: storage)
        XCTAssertEqual(model.block(at: 0).kind, .paragraph)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "## ")
        model.apply(edit: NSRange(location: 0, length: 0), replacementLength: 3)
        model.rescan(afterEditIn: NSRange(location: 0, length: 3))
        XCTAssertEqual(model.block(at: 0).kind, .heading(level: 2))
    }
}

/// A repeatable generator, so a failing property run can be replayed.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next(_ bound: Int) -> Int {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z = z ^ (z >> 31)
        return Int(z % UInt64(max(1, bound)))
    }
}
