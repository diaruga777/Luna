//
//  WriterEditingCommandsTests.swift
//  LunaTests
//

import XCTest
import LunaWriterText

/// Pins the toolbar and Return-key transforms by the text they produce. Every
/// command answers edits from the end of the text backwards, so applying them
/// in order needs no offset arithmetic; these tests apply them that way.
final class WriterEditingCommandsTests: XCTestCase {

    private func applying(_ source: String, _ command: (NSString) -> [TextEdit]?) -> String? {
        let text = NSMutableString(string: source)
        guard let edits = command(text as NSString) else { return nil }
        MarkdownEditingCommands.apply(edits, to: text)
        return text as String
    }

    // MARK: - Applying

    func testApplyReturnsTheFinalRangeWhenMultipleEditsChangeLength() {
        // Both edits insert, so an earlier (lower-location) edit shifts the
        // span the later (higher-location) edit already landed at.
        let text = NSMutableString(string: "abcXdefY")
        let edits = [
            TextEdit(range: NSRange(location: 7, length: 1), replacement: "LATER"),
            TextEdit(range: NSRange(location: 3, length: 1), replacement: "EARLIER"),
        ]
        let range = MarkdownEditingCommands.apply(edits, to: text)
        XCTAssertEqual(text as String, "abcEARLIERdefLATER")
        XCTAssertEqual(text.substring(with: range), "EARLIERdefLATER")
    }

    // MARK: - Wrapping

    func testWrappingASelectionAddsTheMarkerOnBothSides() {
        XCTAssertEqual(applying("hello world") {
            MarkdownEditingCommands.toggleWrap(NSRange(location: 6, length: 5), marker: "**", in: $0)
        }, "hello **world**")
    }

    func testWrappingAgainTakesTheMarkerOff() {
        XCTAssertEqual(applying("hello **world**") {
            MarkdownEditingCommands.toggleWrap(NSRange(location: 6, length: 9), marker: "**", in: $0)
        }, "hello world")
        XCTAssertEqual(applying("hello **world**") {
            MarkdownEditingCommands.toggleWrap(NSRange(location: 8, length: 5), marker: "**", in: $0)
        }, "hello world")
    }

    func testWrappingNothingOpensAnEmptyPair() {
        XCTAssertEqual(applying("ab") {
            MarkdownEditingCommands.toggleWrap(NSRange(location: 1, length: 0), marker: "*", in: $0)
        }, "a**b")
    }

    func testWrappingAtTheVeryStartAndEndOfTheDocument() {
        XCTAssertEqual(applying("word") {
            MarkdownEditingCommands.toggleWrap(NSRange(location: 0, length: 4), marker: "*", in: $0)
        }, "*word*")
        XCTAssertEqual(applying("*word*") {
            MarkdownEditingCommands.toggleWrap(NSRange(location: 1, length: 4), marker: "*", in: $0)
        }, "word")
        // A selection that touches an edge can't have markup outside it.
        XCTAssertEqual(applying("word") {
            MarkdownEditingCommands.toggleWrap(NSRange(location: 0, length: 0), marker: "*", in: $0)
        }, "**word")
    }

    // MARK: - Headings

    func testHeadingLevelIsSetChangedAndRemoved() {
        XCTAssertEqual(applying("plain line\n") { MarkdownEditingCommands.setHeading(2, paragraphAt: 3, in: $0) },
                       "## plain line\n")
        XCTAssertEqual(applying("## plain\n") { MarkdownEditingCommands.setHeading(3, paragraphAt: 3, in: $0) },
                       "### plain\n")
        XCTAssertEqual(applying("### plain\n") { MarkdownEditingCommands.setHeading(0, paragraphAt: 5, in: $0) },
                       "plain\n")
    }

    func testSettingTheLevelALineAlreadyHasChangesNothing() {
        XCTAssertEqual(MarkdownEditingCommands.setHeading(2, paragraphAt: 3, in: "## plain\n" as NSString), [])
    }

    // MARK: - Lists

    private let threeLines = "one\ntwo\nthree\n"
    private var wholeThree: NSRange { NSRange(location: 0, length: 13) }

    func testEveryTouchedLineBecomesAListItem() {
        XCTAssertEqual(applying(threeLines) { MarkdownEditingCommands.toggleList(.bullet, in: wholeThree, of: $0) },
                       "- one\n- two\n- three\n")
        XCTAssertEqual(applying(threeLines) { MarkdownEditingCommands.toggleList(.ordered, in: wholeThree, of: $0) },
                       "1. one\n2. two\n3. three\n")
        XCTAssertEqual(applying(threeLines) { MarkdownEditingCommands.toggleList(.task, in: wholeThree, of: $0) },
                       "- [ ] one\n- [ ] two\n- [ ] three\n")
    }

    func testToggllingTheSameKindAgainRemovesTheMarkers() {
        XCTAssertEqual(applying("- one\n- two\n") {
            MarkdownEditingCommands.toggleList(.bullet, in: NSRange(location: 0, length: 11), of: $0)
        }, "one\ntwo\n")
    }

    func testChangingTheKindReplacesTheMarkers() {
        XCTAssertEqual(applying("- one\n- two\n") {
            MarkdownEditingCommands.toggleList(.ordered, in: NSRange(location: 0, length: 11), of: $0)
        }, "1. one\n2. two\n")
    }

    func testBlankLinesInTheSelectionAreLeftAlone() {
        XCTAssertEqual(applying("one\n\ntwo\n") {
            MarkdownEditingCommands.toggleList(.bullet, in: NSRange(location: 0, length: 8), of: $0)
        }, "- one\n\n- two\n")
    }

    // MARK: - Tasks

    func testTaskBoxTicksAndUnticks() {
        XCTAssertEqual(applying("- [ ] job\n") { MarkdownEditingCommands.toggleTask(at: 3, in: $0) }, "- [x] job\n")
        XCTAssertEqual(applying("- [x] job\n") { MarkdownEditingCommands.toggleTask(at: 3, in: $0) }, "- [ ] job\n")
    }

    func testALineWithNoBoxGetsOne() {
        XCTAssertEqual(applying("job\n") { MarkdownEditingCommands.toggleTask(at: 1, in: $0) }, "- [ ] job\n")
        XCTAssertEqual(applying("- job\n") { MarkdownEditingCommands.toggleTask(at: 3, in: $0) }, "- [ ] job\n")
    }

    // MARK: - Return

    func testReturnContinuesEachKindOfList() {
        XCTAssertEqual(applying("- one") { MarkdownEditingCommands.continueList(onReturnAt: 5, in: $0) }, "- one\n- ")
        XCTAssertEqual(applying("3. one") { MarkdownEditingCommands.continueList(onReturnAt: 6, in: $0) }, "3. one\n4. ")
        XCTAssertEqual(applying("- [x] one") { MarkdownEditingCommands.continueList(onReturnAt: 9, in: $0) }, "- [x] one\n- [ ] ")
        XCTAssertEqual(applying("> one") { MarkdownEditingCommands.continueList(onReturnAt: 5, in: $0) }, "> one\n> ")
    }

    func testReturnKeepsTheIndentOfANestedItem() {
        XCTAssertEqual(applying("  - one") { MarkdownEditingCommands.continueList(onReturnAt: 7, in: $0) }, "  - one\n  - ")
    }

    func testReturnOnAnEmptyItemEndsTheList() {
        XCTAssertEqual(applying("- one\n- ") { MarkdownEditingCommands.continueList(onReturnAt: 8, in: $0) }, "- one\n")
    }

    func testReturnOnAPlainLineIsTheCallersToHandle() {
        XCTAssertNil(MarkdownEditingCommands.continueList(onReturnAt: 3, in: "one" as NSString))
    }

    // MARK: - Indenting

    func testIndentAndOutdentMoveEveryTouchedLine() {
        XCTAssertEqual(applying("one\ntwo\n") {
            MarkdownEditingCommands.indent(NSRange(location: 0, length: 7), in: $0)
        }, "    one\n    two\n")
        XCTAssertEqual(applying("    one\n\ttwo\n") {
            MarkdownEditingCommands.outdent(NSRange(location: 0, length: 12), in: $0)
        }, "one\ntwo\n")
    }

    func testOutdentingALineWithNoIndentChangesNothing() {
        XCTAssertEqual(MarkdownEditingCommands.outdent(NSRange(location: 0, length: 3), in: "one\n" as NSString), [])
    }
}
