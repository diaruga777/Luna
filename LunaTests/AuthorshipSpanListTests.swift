//
//  AuthorshipSpanListTests.swift
//  LunaTests
//

import XCTest
@testable import LunaWriterEditor
import LunaWriterModels

final class AuthorshipSpanListTests: XCTestCase {

    private func pairs(_ list: AuthorshipSpanList) -> [(NSRange, AuthorshipSpan.Source)] {
        list.spans.map { ($0.range.nsRange, $0.source) }
    }

    private func assertSpans(
        _ list: AuthorshipSpanList, _ expected: [(NSRange, AuthorshipSpan.Source)],
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let actual = pairs(list)
        XCTAssertEqual(actual.count, expected.count, "\(actual)", file: file, line: line)
        guard actual.count == expected.count else { return }
        for (index, expectation) in expected.enumerated() {
            XCTAssertEqual(actual[index].0, expectation.0, "span \(index)", file: file, line: line)
            XCTAssertEqual(actual[index].1, expectation.1, "span \(index)", file: file, line: line)
        }
    }

    private func pasted(_ location: Int, _ length: Int) -> AuthorshipSpan {
        AuthorshipSpan(range: NSRange(location: location, length: length), source: .pasted)
    }

    // MARK: - Typing

    func testTypingInsideAPastedSpanSplitsIt() {
        var list = AuthorshipSpanList(spans: [pasted(0, 10)])
        list.apply(edit: NSRange(location: 4, length: 0), replacementLength: 2, typedBy: .author)
        assertSpans(list, [
            (NSRange(location: 0, length: 4), .pasted),
            (NSRange(location: 4, length: 2), .author),
            (NSRange(location: 6, length: 6), .pasted),
        ])
    }

    func testTypingAfterAPastedSpanDoesNotExtendIt() {
        var list = AuthorshipSpanList(spans: [pasted(0, 5)])
        list.apply(edit: NSRange(location: 5, length: 0), replacementLength: 3, typedBy: .author)
        assertSpans(list, [
            (NSRange(location: 0, length: 5), .pasted),
            (NSRange(location: 5, length: 3), .author),
        ])
    }

    func testTypingBeforeAPastedSpanDoesNotExtendIt() {
        var list = AuthorshipSpanList(spans: [pasted(5, 5)])
        list.apply(edit: NSRange(location: 5, length: 0), replacementLength: 2, typedBy: .author)
        assertSpans(list, [
            (NSRange(location: 5, length: 2), .author),
            (NSRange(location: 7, length: 5), .pasted),
        ])
    }

    func testTypingExtendsTheAuthorSpanItTouches() {
        var list = AuthorshipSpanList(spans: [
            AuthorshipSpan(range: NSRange(location: 0, length: 4), source: .author)
        ])
        list.apply(edit: NSRange(location: 4, length: 0), replacementLength: 1, typedBy: .author)
        list.apply(edit: NSRange(location: 5, length: 0), replacementLength: 1, typedBy: .author)
        assertSpans(list, [(NSRange(location: 0, length: 6), .author)])
    }

    func testTypingWithNoSourceLeavesTheNewCharactersUnattributed() {
        var list = AuthorshipSpanList(spans: [pasted(0, 6)])
        list.apply(edit: NSRange(location: 3, length: 0), replacementLength: 2, typedBy: nil)
        assertSpans(list, [
            (NSRange(location: 0, length: 3), .pasted),
            (NSRange(location: 5, length: 3), .pasted),
        ])
        XCTAssertNil(list.source(at: 3))
    }

    // MARK: - Deleting

    func testDeletingInsideASpanShrinksIt() {
        var list = AuthorshipSpanList(spans: [pasted(0, 10)])
        list.apply(edit: NSRange(location: 2, length: 3), replacementLength: 0, typedBy: .author)
        assertSpans(list, [(NSRange(location: 0, length: 7), .pasted)])
    }

    func testDeletingASpanEntirelyDropsIt() {
        var list = AuthorshipSpanList(spans: [pasted(0, 4), pasted(10, 4)])
        list.apply(edit: NSRange(location: 0, length: 4), replacementLength: 0, typedBy: nil)
        assertSpans(list, [(NSRange(location: 6, length: 4), .pasted)])
    }

    func testADeletionAcrossTwoSpansJoinsWhatSurvives() {
        var list = AuthorshipSpanList(spans: [pasted(0, 5), pasted(10, 5)])
        list.apply(edit: NSRange(location: 3, length: 9), replacementLength: 0, typedBy: nil)
        assertSpans(list, [(NSRange(location: 0, length: 6), .pasted)])
    }

    func testReplacingASelectionByTypingRecordsOnlyTheTypedText() {
        var list = AuthorshipSpanList(spans: [pasted(0, 10)])
        list.apply(edit: NSRange(location: 2, length: 6), replacementLength: 1, typedBy: .author)
        assertSpans(list, [
            (NSRange(location: 0, length: 2), .pasted),
            (NSRange(location: 2, length: 1), .author),
            (NSRange(location: 3, length: 2), .pasted),
        ])
    }

    // MARK: - Recording

    func testRecordingAPasteReplacesWhateverTheRangeHeld() {
        var list = AuthorshipSpanList(spans: [
            AuthorshipSpan(range: NSRange(location: 0, length: 10), source: .author)
        ])
        list.record(range: NSRange(location: 3, length: 4), source: .pasted)
        assertSpans(list, [
            (NSRange(location: 0, length: 3), .author),
            (NSRange(location: 3, length: 4), .pasted),
            (NSRange(location: 7, length: 3), .author),
        ])
    }

    func testAIWritingIsRecordedWithItsModel() {
        var list = AuthorshipSpanList()
        list.record(range: NSRange(location: 0, length: 5), source: .ai(model: "apple-on-device"))
        XCTAssertEqual(list.source(at: 2), .ai(model: "apple-on-device"))
        XCTAssertTrue(list.containsForeignText(in: NSRange(location: 0, length: 5)))
    }

    // MARK: - Mark as mine

    func testMarkAsOwnTakesTheMiddleOfAForeignSpan() {
        var list = AuthorshipSpanList(spans: [pasted(0, 12)])
        list.markAsOwn(NSRange(location: 4, length: 4))
        assertSpans(list, [
            (NSRange(location: 0, length: 4), .pasted),
            (NSRange(location: 4, length: 4), .author),
            (NSRange(location: 8, length: 4), .pasted),
        ])
        XCTAssertFalse(list.containsForeignText(in: NSRange(location: 4, length: 4)))
    }

    func testMarkAsOwnAcrossTwoForeignSpansLeavesOneAuthorSpan() {
        var list = AuthorshipSpanList(spans: [
            pasted(0, 5),
            AuthorshipSpan(range: NSRange(location: 5, length: 5), source: .ai(model: "m")),
        ])
        list.markAsOwn(NSRange(location: 0, length: 10))
        assertSpans(list, [(NSRange(location: 0, length: 10), .author)])
    }

    // MARK: - Reading

    func testSpansAreClippedToTheRangeAsked() {
        let list = AuthorshipSpanList(spans: [pasted(0, 10)])
        let clipped = list.spans(in: NSRange(location: 4, length: 3))
        XCTAssertEqual(clipped.map { $0.range.nsRange }, [NSRange(location: 4, length: 3)])
    }

    func testUnrecordedTextHasNoSource() {
        let list = AuthorshipSpanList(spans: [pasted(10, 4)])
        XCTAssertNil(list.source(at: 2))
        XCTAssertEqual(list.source(at: 11), .pasted)
        XCTAssertFalse(list.containsForeignText(in: NSRange(location: 0, length: 10)))
    }

    func testLoadingUnsortedSpansSortsAndMergesThem() {
        let list = AuthorshipSpanList(spans: [
            AuthorshipSpan(range: NSRange(location: 6, length: 4), source: .author),
            pasted(0, 3),
            AuthorshipSpan(range: NSRange(location: 3, length: 3), source: .author),
        ])
        assertSpans(list, [
            (NSRange(location: 0, length: 3), .pasted),
            (NSRange(location: 3, length: 7), .author),
        ])
    }

    /// Malformed persisted marks can hand normalised(_:) two overlapping
    /// spans where the later, different-source one sits entirely INSIDE the
    /// earlier one. The stretch of the earlier span after the overlap must
    /// survive as its own span, not vanish along with the middle it lost.
    func testLoadingOverlappingSpansEmitsTheTrailingRemainder() {
        let list = AuthorshipSpanList(spans: [
            pasted(0, 20),
            AuthorshipSpan(range: NSRange(location: 5, length: 5), source: .author),
        ])
        assertSpans(list, [
            (NSRange(location: 0, length: 5), .pasted),
            (NSRange(location: 5, length: 5), .author),
            (NSRange(location: 10, length: 10), .pasted),
        ])
    }

    func testATypedRunOverManySpansStaysCheapToRead() {
        var list = AuthorshipSpanList(spans: (0..<200).map { pasted($0 * 10, 5) })
        list.apply(edit: NSRange(location: 1000, length: 0), replacementLength: 1, typedBy: .author)
        XCTAssertEqual(list.source(at: 1000), .author)
        XCTAssertEqual(list.source(at: 1002), .pasted)
    }
}
