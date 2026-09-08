//
//  WriterTextAnchorResolverTests.swift
//  LunaWriterTests
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

    /// The stored quote is capped, but the suffix must pick up exactly where
    /// the capped quote ends, not where the untruncated selection did —
    /// otherwise `prefix + exact + suffix` is never contiguous in the real
    /// document and the context search can never match.
    func testALongMidDocumentSelectionWithRealContextSurvivesAnEditAbove() {
        let longQuote = String(repeating: "word ", count: 120).trimmingCharacters(in: .whitespaces)
        XCTAssertGreaterThan((longQuote as NSString).length, TextAnchor.exactLimit)
        let original = "Before this. " + longQuote + " After this." as NSString
        let range = original.range(of: longQuote)
        let made = TextAnchorResolver.make(range: range, in: original)
        XCTAssertLessThan((made.exact as NSString).length, range.length)

        let shifted = ("A new paragraph above.\n\n" + (original as String)) as NSString
        let resolvedRange = TextAnchorResolver.resolve(made, in: shifted)
        XCTAssertEqual(resolvedRange.map { shifted.substring(with: $0) }, longQuote)
    }

    /// The emoji sits astride the prefix window's own start (17 filler units,
    /// a 2-unit emoji, 31 more filler units, `contextLimit` = 32 back from the
    /// selection — the window's naive start lands on the emoji's low
    /// surrogate). Snapping must drop the whole emoji rather than a half.
    func testContextNeverSplitsASurrogatePairAtTheWindowEdge() {
        let emoji = "🙂"
        let afterEmoji = String(repeating: "x", count: 31)
        let document = (String(repeating: "x", count: 17) + emoji + afterEmoji + "TARGET"
            + String(repeating: "y", count: 40)) as NSString
        let range = document.range(of: "TARGET")
        XCTAssertEqual(range.location - TextAnchor.contextLimit, 18,
                        "the prefix window must start mid-surrogate-pair for this test to mean anything")

        let made = TextAnchorResolver.make(range: range, in: document)
        XCTAssertFalse(made.prefix.contains("\u{FFFD}"), "a snapped prefix must never carry half of a surrogate pair")
        XCTAssertEqual(made.prefix, afterEmoji, "the split emoji is dropped whole, not sliced")
        XCTAssertEqual(TextAnchorResolver.resolve(made, in: document), range)
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
