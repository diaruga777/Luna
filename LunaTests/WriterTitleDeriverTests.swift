//
//  WriterTitleDeriverTests.swift
//  LunaTests
//

import XCTest
import LunaWriterText

/// Pins how a sheet names itself. The library stores whatever this answers,
/// and nil means the caller shows its own untitled wording: this tier holds
/// no strings of its own.
final class WriterTitleDeriverTests: XCTestCase {

    private func title(_ markdown: String) -> String? {
        TitleDeriver.derive(from: markdown as NSString)?.text
    }

    func testHeadingIsTheTitleAndItsMarkupIsGone() {
        XCTAssertEqual(title("# Real *title* here\nbody\n"), "Real title here")
        XCTAssertEqual(title("### Third level `code`\n"), "Third level code")
    }

    func testHeadingWinsOverAnEarlierPlainLine() {
        XCTAssertEqual(title("plain opening line\n# The heading\n"), "The heading")
    }

    func testFirstLineWithWordsTitlesADocumentWithNoHeading() {
        XCTAssertEqual(title("\n\n  \nfirst real line\nsecond line\n"), "first real line")
        XCTAssertEqual(title("- item one\n- item two\n"), "item one")
        XCTAssertEqual(title("> quoted opening\n"), "quoted opening")
    }

    func testDocumentWithNothingToNameItHasNoTitle() {
        XCTAssertNil(title(""))
        XCTAssertNil(title("\n\n   \n\t\n"))
        XCTAssertNil(title("---\n***\n"))
    }

    func testHeadingIsReportedWithItsLineAndKind() {
        let derived = TitleDeriver.derive(from: "intro line\n## Later\n" as NSString)
        XCTAssertEqual(derived?.isHeading, true)
        XCTAssertEqual(derived?.text, "Later")
        let plain = TitleDeriver.derive(from: "only a line\n" as NSString)
        XCTAssertEqual(plain?.isHeading, false)
        XCTAssertEqual(plain?.lineRange, NSRange(location: 0, length: 12))
    }

    func testSnippetIsTheBodyWithoutTheTitleLine() {
        let source = "# Title\nfirst body line\nsecond body line\n" as NSString
        let derived = TitleDeriver.derive(from: source)
        XCTAssertEqual(TitleDeriver.snippet(of: source, after: derived), "first body line second body line")
    }

    func testSnippetDropsMarkupAndRules() {
        let source = "# Title\n\n---\n\n- **bold** item\n" as NSString
        let derived = TitleDeriver.derive(from: source)
        XCTAssertEqual(TitleDeriver.snippet(of: source, after: derived), "bold item")
    }

    func testSnippetSkipsEveryLineUpToAndIncludingTheTitleNotJustTheTitleLine() {
        let source = "intro before the title\n# Title\nbody line\n" as NSString
        let derived = TitleDeriver.derive(from: source)
        XCTAssertEqual(derived?.text, "Title")
        XCTAssertEqual(TitleDeriver.snippet(of: source, after: derived), "body line")
    }

    func testSnippetNeverCutsMidWordEvenWithNoSpaceNearTheLimit() {
        let word = String(repeating: "a", count: 200)
        let source = ("# Title\n" + word + "\n") as NSString
        let snippet = TitleDeriver.snippet(of: source, after: TitleDeriver.derive(from: source), limit: 20)
        XCTAssertEqual(snippet, word)
    }

    func testSnippetStopsAtTheLimitOnAWordBoundary() {
        let body = String(repeating: "alpha beta ", count: 40)
        let source = ("# Title\n" + body) as NSString
        let snippet = TitleDeriver.snippet(of: source, after: TitleDeriver.derive(from: source), limit: 20)
        XCTAssertLessThanOrEqual(snippet.count, 20)
        XCTAssertFalse(snippet.hasSuffix(" "))
        XCTAssertTrue(body.hasPrefix(snippet), "the snippet must be the start of the body")
    }
}
