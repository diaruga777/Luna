//
//  LineTableTests.swift
//  LunaWriterTests
//

import XCTest
@testable import LunaWriterText

/// Pins `LineTable` directly: the incremental rescan in
/// `MarkdownDocumentModel` is only as correct as the line starts underneath
/// it, and the chunked scan that builds them has its own boundary to get
/// right independent of anything Markdown-specific.
final class LineTableTests: XCTestCase {

    private func referenceLineRanges(of text: NSString) -> [NSRange] {
        var out: [NSRange] = []
        var location = 0
        while location < text.length {
            let range = text.lineRange(for: NSRange(location: location, length: 0))
            out.append(range)
            guard NSMaxRange(range) > location else { break }
            location = NSMaxRange(range)
        }
        if out.isEmpty { out.append(NSRange(location: 0, length: 0)) }
        return out
    }

    // MARK: - The 8192-unit chunk boundary

    func testManyCRLFLinesAcrossSeveralChunkBoundariesAllCount() {
        let source = String(repeating: "line\r\n", count: 3000)
        let table = LineTable(text: source as NSString)
        XCTAssertEqual(table.lineCount, 3000)
    }

    func testACRLFPairSplitExactlyAcrossTheChunkBoundaryIsOneLineBreak() {
        // The '\r' lands on the last unit of the first 8192-unit chunk and
        // the '\n' on the first unit of the next: a duplicate line start
        // here means the table over-counts by one every time this happens.
        let prefix = String(repeating: "x", count: 8191)
        let source = prefix + "\r\n" + String(repeating: "line\r\n", count: 10)
        let table = LineTable(text: source as NSString)
        XCTAssertEqual(table.lineCount, 11)
        XCTAssertEqual(referenceLineRanges(of: source as NSString).map { $0.location },
                        (0..<table.lineCount).map { table.lineRange(at: $0).location })
    }

    // MARK: - NEL

    /// Measured directly against `NSString.lineRange(for:)`: NEL (U+0085)
    /// breaks a line there, but form feed and vertical tab do not, despite
    /// both being members of `NSCharacterSet.newlines`. `LineTable` must
    /// match the actual algorithm, not the character set's membership list.
    func testNELIsALineBoundaryLikeNSStringButFormFeedAndVerticalTabAreNot() {
        let source = "one\u{0085}two\u{000C}three\u{000B}four"
        let text = source as NSString
        let table = LineTable(text: text)
        let expected = referenceLineRanges(of: text)
        XCTAssertEqual(table.lineCount, expected.count)
        for index in 0..<table.lineCount {
            XCTAssertEqual(table.lineRange(at: index), expected[index])
        }
        XCTAssertEqual(table.lineCount, 2, "only the NEL should split this text")
    }

    // MARK: - Editing across a CRLF boundary the edit itself creates

    func testAnEditThatEndsInABareCRImmediatelyBeforeAnUntouchedLFStaysOneBoundary() {
        // Deleting "Xdef" from "abcXdefdefine\nghi" and inserting "\r" leaves
        // the untouched '\n' immediately after the new '\r': the region the
        // edit rescans must land exactly on the resulting CRLF's real end.
        var table = LineTable(text: "abcXdef\nghi" as NSString)
        let mutable = NSMutableString(string: "abcXdef\nghi")
        mutable.replaceCharacters(in: NSRange(location: 3, length: 4), with: "\r")
        let splice = table.apply(edit: NSRange(location: 3, length: 4), replacementLength: 1, text: mutable)
        XCTAssertEqual(mutable as String, "abc\r\nghi")
        XCTAssertEqual(table.lineCount, 2)
        XCTAssertEqual(table.lineRange(at: 0), NSRange(location: 0, length: 5))
        XCTAssertEqual(table.lineRange(at: 1), NSRange(location: 5, length: 3))
        XCTAssertEqual(splice.removed, 0..<1)
    }

    // MARK: - Reading

    func testLineIndexClampsToTheLastLineForAnOffsetPastTheEnd() {
        let table = LineTable(text: "abc\ndef" as NSString)
        XCTAssertEqual(table.lineIndex(at: 100), 1)
        XCTAssertEqual(table.lineIndex(at: -5), 0)
    }

    func testAnEmptyDocumentHasOneZeroLengthLine() {
        let table = LineTable(text: "" as NSString)
        XCTAssertEqual(table.lineCount, 1)
        XCTAssertEqual(table.lineRange(at: 0), NSRange(location: 0, length: 0))
    }
}
