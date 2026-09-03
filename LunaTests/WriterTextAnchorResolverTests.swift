//
//  WriterTextAnchorResolverTests.swift
//  LunaTests
//

import XCTest
import LunaWriterModels
import LunaWriterText

/// Pins how a note or an annotation finds its place again after the sheet
/// has been edited. A wrong answer points a comment at the wrong sentence,
/// so the resolver must prefer saying nothing to guessing.
final class WriterTextAnchorResolverTests: XCTestCase {

    private let document = "The quick brown fox jumps over the lazy dog. A second sentence follows here." as NSString
    private let quote = "jumps over the lazy dog"

    private func anchor(_ text: String? = nil) -> TextAnchor {
        let source = text.map { $0 as NSString } ?? document
        return TextAnchorResolver.make(range: source.range(of: quote), in: source)
    }

    private func resolved(in text: String) -> String? {
        let target = text as NSString
        return TextAnchorResolver.resolve(anchor(), in: target).map { target.substring(with: $0) }
    }

    // MARK: - Making

    func testAnchorKeepsTheQuoteAndItsNeighbours() {
        let made = anchor()
        XCTAssertEqual(made.exact, quote)
        XCTAssertEqual(made.start, document.range(of: quote).location)
        XCTAssertTrue(document.substring(to: made.start).hasSuffix(made.prefix))
        XCTAssertTrue(document.substring(from: made.end).hasPrefix(made.suffix))
        XCTAssertFalse(made.prefix.isEmpty)
        XCTAssertFalse(made.suffix.isEmpty)
    }

    func testALongSelectionKeepsAShorterQuoteAndStillResolves() {
        let long = String(repeating: "abcde ", count: 200) as NSString
        let whole = NSRange(location: 0, length: long.length)
        let made = TextAnchorResolver.make(range: whole, in: long)
        XCTAssertLessThan((made.exact as NSString).length, long.length)
        XCTAssertEqual(TextAnchorResolver.resolve(made, in: long), whole)
    }

    // MARK: - Resolving

    func testUnchangedTextResolvesToTheSavedOffsets() {
        XCTAssertEqual(TextAnchorResolver.resolve(anchor(), in: document), document.range(of: quote))
    }

    func testTextInsertedAboveShiftsTheAnchor() {
        let shifted = "A new opening paragraph.\n\n" + (document as String)
        XCTAssertEqual(resolved(in: shifted), quote)
        let target = shifted as NSString
        XCTAssertEqual(TextAnchorResolver.resolve(anchor(), in: target), target.range(of: quote))
    }

    func testTwoCopiesResolveToTheOneNearestTheSavedOffsets() {
        let twice = (document as String) + " " + (document as String)
        let target = twice as NSString
        XCTAssertEqual(TextAnchorResolver.resolve(anchor(), in: target), target.range(of: quote))
    }

    func testAQuotePushedPastTheSearchWindowIsStillFoundByItsContext() {
        let moved = String(repeating: "filler line here. ", count: 300) + (document as String)
        let target = moved as NSString
        XCTAssertEqual(TextAnchorResolver.resolve(anchor(), in: target), target.range(of: quote))
    }

    func testASmallEditInsideTheQuoteStillResolves() {
        let typo = (document as String).replacingOccurrences(of: "jumps over", with: "jumps ovar")
        XCTAssertEqual(resolved(in: typo), "jumps ovar the lazy dog")
    }

    func testAQuoteEditedBeyondRecognitionIsOrphaned() {
        let rewritten = (document as String).replacingOccurrences(of: quote, with: "sprints past a sleeping cat")
        XCTAssertNil(TextAnchorResolver.resolve(anchor(), in: rewritten as NSString))
    }

    func testAQuoteThatIsGoneIsOrphaned() {
        XCTAssertNil(TextAnchorResolver.resolve(anchor(), in: "Nothing here resembles the original." as NSString))
        XCTAssertNil(TextAnchorResolver.resolve(anchor(), in: "" as NSString))
    }

    func testAnEmptyAnchorResolvesToACaretPositionOrNothing() {
        let caret = TextAnchorResolver.make(range: NSRange(location: 4, length: 0), in: document)
        XCTAssertEqual(TextAnchorResolver.resolve(caret, in: document), NSRange(location: 4, length: 0))
        XCTAssertNil(TextAnchorResolver.resolve(caret, in: "ab" as NSString))
    }
}
