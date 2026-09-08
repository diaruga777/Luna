//
//  MarkdownTextStorageTests.swift
//  LunaWriterTests
//

import XCTest
import UIKit
@testable import LunaWriterEditor
import LunaWriterText

/// The storage owns the layout channel: fonts and paragraph styles per block.
final class MarkdownTextStorageTests: XCTestCase {

    private func font(_ storage: MarkdownTextStorage, at location: Int) -> UIFont? {
        storage.attributes(at: location, effectiveRange: nil)[.font] as? UIFont
    }

    private func paragraphStyle(_ storage: MarkdownTextStorage, at location: Int) -> NSParagraphStyle? {
        storage.attributes(at: location, effectiveRange: nil)[.paragraphStyle] as? NSParagraphStyle
    }

    /// TextKit draws a run with no foreground colour in black, so a storage
    /// that dropped the ink while restyling drew typed text black on the
    /// night background.
    func testTypedTextKeepsTheInkColourAfterRestyling() throws {
        let storage = MarkdownTextStorage(text: "Body\n")
        storage.replaceCharacters(in: NSRange(location: 4, length: 0), with: " and **more**")
        for location in [0, 6, 12] {
            let colour = storage.attributes(at: location, effectiveRange: nil)[.foregroundColor] as? UIColor
            XCTAssertEqual(colour, EditorTheme.ink, "no ink at \(location)")
        }
    }

    func testHeadingLineCarriesALargerBoldFontThanBody() throws {
        let storage = MarkdownTextStorage(text: "# Title\nBody text\n")
        let heading = try XCTUnwrap(font(storage, at: 2))
        let body = try XCTUnwrap(font(storage, at: 10))
        XCTAssertGreaterThan(heading.pointSize, body.pointSize)
        XCTAssertTrue(heading.fontDescriptor.symbolicTraits.contains(.traitBold))
        XCTAssertFalse(body.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    func testTypingAHashTurnsTheLineIntoAHeading() throws {
        let storage = MarkdownTextStorage(text: "Title\nBody\n")
        let before = try XCTUnwrap(font(storage, at: 2))
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "## ")
        let after = try XCTUnwrap(font(storage, at: 5))
        XCTAssertGreaterThan(after.pointSize, before.pointSize)
        XCTAssertTrue(after.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    func testOpeningAFenceRestylesTheLinesBelowIt() throws {
        let storage = MarkdownTextStorage(text: "alpha\nbravo\ncharlie\n")
        let plain = try XCTUnwrap(font(storage, at: 8))
        XCTAssertFalse(plain.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))

        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "```\n")

        // "bravo" now sits inside the fence, three lines below the edit.
        let fenced = try XCTUnwrap(font(storage, at: NSString(string: storage.string).range(of: "bravo").location))
        XCTAssertTrue(fenced.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
    }

    func testClosingAFenceReturnsTheLinesBelowToBody() throws {
        let storage = MarkdownTextStorage(text: "```\nalpha\nbravo\n")
        let inside = try XCTUnwrap(font(storage, at: NSString(string: storage.string).range(of: "bravo").location))
        XCTAssertTrue(inside.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))

        let alpha = NSString(string: storage.string).range(of: "alpha")
        storage.replaceCharacters(in: NSRange(location: NSMaxRange(alpha) + 1, length: 0), with: "```\n")

        let after = try XCTUnwrap(font(storage, at: NSString(string: storage.string).range(of: "bravo").location))
        XCTAssertFalse(after.fontDescriptor.symbolicTraits.contains(.traitMonoSpace))
    }

    func testListItemIndentsItsWrappedLines() throws {
        let storage = MarkdownTextStorage(text: "plain\n- item\n")
        let plain = try XCTUnwrap(paragraphStyle(storage, at: 1))
        let item = try XCTUnwrap(paragraphStyle(storage, at: NSString(string: storage.string).range(of: "item").location))
        XCTAssertEqual(plain.headIndent, 0)
        XCTAssertGreaterThan(item.headIndent, 0)
    }

    func testEmphasisAddsItalicToTheContentOnly() throws {
        let storage = MarkdownTextStorage(text: "one *two* three\n")
        let content = NSString(string: storage.string).range(of: "two")
        let emphasised = try XCTUnwrap(font(storage, at: content.location))
        let plain = try XCTUnwrap(font(storage, at: 0))
        XCTAssertTrue(emphasised.fontDescriptor.symbolicTraits.contains(.traitItalic))
        XCTAssertFalse(plain.fontDescriptor.symbolicTraits.contains(.traitItalic))
    }

    func testRescanIsReportedToTheObserver() throws {
        final class Recorder: MarkdownTextStorageObserving {
            var ranges: [NSRange] = []
            func markdownTextStorage(_ storage: MarkdownTextStorage, didRescan range: NSRange) {
                ranges.append(range)
            }
        }
        let storage = MarkdownTextStorage(text: "alpha\nbravo\n")
        let recorder = Recorder()
        storage.addObserver(recorder)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "X")
        XCTAssertEqual(recorder.ranges.count, 1)
        XCTAssertEqual(recorder.ranges.first?.location, 0)
    }

    func testRevisionBumpsOnEveryCharacterEdit() throws {
        let storage = MarkdownTextStorage(text: "a")
        let start = storage.revision
        storage.replaceCharacters(in: NSRange(location: 1, length: 0), with: "b")
        storage.replaceCharacters(in: NSRange(location: 2, length: 0), with: "c")
        XCTAssertEqual(storage.revision, start + 2)
    }

    // MARK: - Two edits, one editing group

    /// Two edits that touch neither the same, nor adjacent, text — inside one
    /// `beginEditing`/`endEditing` pair — must each rescan against the text
    /// as it stood right after ITS OWN splice, not a range that describes
    /// neither edit. The model's own pending-lines union (not a second,
    /// hand-rolled one in the storage) is what keeps this correct.
    func testTwoDisjointEditsInOneEditingGroupRescanBothCorrectly() throws {
        let base = "plain\nsecond line of plain body text that stretches out long enough to be edited near its very end here\n"
        let storage = MarkdownTextStorage(text: base)
        let ns = NSString(string: base)
        let secondLineStart = ns.range(of: "second").location
        let tailWord = ns.range(of: "here")

        storage.beginEditing()
        // Edit 1: turn the first line into a heading.
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# ")
        // Edit 2, same group: replace a word near the end of the second line.
        // Its range is against the text as edit 1 already left it, exactly as
        // UIKit itself would supply it.
        storage.replaceCharacters(
            in: NSRange(location: tailWord.location + 2, length: tailWord.length), with: "THERE")
        storage.endEditing()

        XCTAssertTrue(storage.string.hasPrefix("# plain"))
        XCTAssertTrue(storage.string.contains("THERE"))
        XCTAssertFalse(storage.string.contains("here\n"))
        XCTAssertEqual(storage.length, (storage.string as NSString).length)

        let heading = try XCTUnwrap(font(storage, at: 2))
        XCTAssertTrue(heading.fontDescriptor.symbolicTraits.contains(.traitBold))

        // The second line's own font survived edit 1's shift correctly: it
        // reads as plain body, not a stale or out-of-range scan.
        let secondLineFont = try XCTUnwrap(font(storage, at: secondLineStart + 2))
        XCTAssertFalse(secondLineFont.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    /// Two edits in one group report their rescan as a single pass to
    /// observers, not once per `replaceCharacters` call.
    func testTwoEditsInOneGroupNotifyTheObserverOnce() throws {
        final class Recorder: MarkdownTextStorageObserving {
            var count = 0
            func markdownTextStorage(_ storage: MarkdownTextStorage, didRescan range: NSRange) { count += 1 }
        }
        let storage = MarkdownTextStorage(text: "alpha bravo\ncharlie delta\n")
        let recorder = Recorder()
        storage.addObserver(recorder)

        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: 5), with: "ALPHA")
        storage.replaceCharacters(in: NSRange(location: 12, length: 7), with: "CHARLIE")
        storage.endEditing()

        XCTAssertEqual(recorder.count, 1)
    }

    // MARK: - Live Markdown

    private func kern(_ storage: MarkdownTextStorage, at location: Int) -> CGFloat? {
        (storage.attributes(at: location, effectiveRange: nil)[.kern] as? NSNumber)
            .map { CGFloat($0.doubleValue) }
    }

    /// A hidden marker keeps its characters — every offset in the document
    /// still maps one to one — and lays out zero points wide.
    func testAMarkerAwayFromTheCaretCollapsesToZeroWidth() throws {
        let storage = MarkdownTextStorage(text: "# Title\nBody\n")
        var effective = NSRange(location: 0, length: 0)
        let attributes = storage.attributes(at: 0, effectiveRange: &effective)
        let marker = try XCTUnwrap(attributes[.font] as? UIFont)
        let kern = try XCTUnwrap(kern(storage, at: 0))

        // The hashes and the space after them, and nothing else.
        XCTAssertEqual(effective, NSRange(location: 0, length: 2))
        XCTAssertEqual(marker.pointSize, LayoutAttributeStyler.hiddenMarkerSize, accuracy: 0.0001)
        let run = "# " as NSString
        let width = run.size(withAttributes: [.font: marker]).width
        XCTAssertEqual(width + CGFloat(run.length) * kern, 0, accuracy: 0.001)
        XCTAssertEqual(storage.string, "# Title\nBody\n")
    }

    func testAMarkerOnTheCaretsParagraphKeepsTheBlockFont() throws {
        let storage = MarkdownTextStorage(text: "# Title\nBody\n")
        storage.setRevealRange(NSRange(location: 3, length: 0))
        let marker = try XCTUnwrap(font(storage, at: 0))
        let content = try XCTUnwrap(font(storage, at: 2))
        XCTAssertEqual(marker.pointSize, content.pointSize)
        XCTAssertNil(kern(storage, at: 0))
    }

    /// Moving the caret to another paragraph collapses the one it left.
    func testLeavingAParagraphCollapsesItsMarkersAgain() throws {
        let storage = MarkdownTextStorage(text: "# Title\nBody\n")
        storage.setRevealRange(NSRange(location: 3, length: 0))
        storage.setRevealRange(NSRange(location: 9, length: 0))
        let marker = try XCTUnwrap(font(storage, at: 0))
        XCTAssertEqual(marker.pointSize, LayoutAttributeStyler.hiddenMarkerSize, accuracy: 0.0001)
    }

    func testEmphasisMarkersCollapseWhileItsContentKeepsItsFace() throws {
        let storage = MarkdownTextStorage(text: "one **two** three\n")
        let stars = try XCTUnwrap(font(storage, at: 4))
        let content = try XCTUnwrap(font(storage, at: 6))
        XCTAssertEqual(stars.pointSize, LayoutAttributeStyler.hiddenMarkerSize, accuracy: 0.0001)
        XCTAssertTrue(content.fontDescriptor.symbolicTraits.contains(.traitBold))
    }

    /// Nothing paints a number in an ordered item's place, so its marker
    /// stays where the writer typed it.
    func testAnOrderedListItemKeepsItsNumberVisible() throws {
        let storage = MarkdownTextStorage(text: "1. one\n- two\n")
        let number = try XCTUnwrap(font(storage, at: 0))
        let bullet = try XCTUnwrap(font(storage, at: 7))
        XCTAssertEqual(number.pointSize, storage.styler.bodyFont.pointSize)
        XCTAssertEqual(bullet.pointSize, LayoutAttributeStyler.hiddenMarkerSize, accuracy: 0.0001)
    }

    /// The backticks are the code, so a fence keeps every character.
    func testAFenceKeepsItsDelimitersVisible() throws {
        let storage = MarkdownTextStorage(text: "```\nlet a = 1\n```\n")
        let delimiter = try XCTUnwrap(font(storage, at: 0))
        XCTAssertEqual(delimiter.pointSize, storage.styler.codeFont.pointSize)
        XCTAssertNil(kern(storage, at: 0))
    }

    /// A caret move costs two paragraphs, whatever the document's length.
    func testMovingTheRevealRangeRestylesTheOldAndTheNewParagraphOnly() throws {
        final class Recorder: MarkdownTextStorageObserving {
            var ranges: [NSRange] = []
            func markdownTextStorage(_ storage: MarkdownTextStorage, didRescan range: NSRange) {
                ranges.append(range)
            }
        }
        let storage = MarkdownTextStorage(text: "# One\n\n# Two\n\n# Three\n")
        let recorder = Recorder()
        storage.addObserver(recorder)

        storage.setRevealRange(NSRange(location: 0, length: 0))
        XCTAssertEqual(recorder.ranges, [NSRange(location: 0, length: 6)])

        recorder.ranges = []
        storage.setRevealRange(NSRange(location: 7, length: 0))
        XCTAssertEqual(
            recorder.ranges,
            [NSRange(location: 0, length: 6), NSRange(location: 7, length: 6)])
    }

    /// The same caret twice is not a restyle.
    func testSettingTheSameRevealRangeAgainRestylesNothing() throws {
        final class Recorder: MarkdownTextStorageObserving {
            var count = 0
            func markdownTextStorage(_ storage: MarkdownTextStorage, didRescan range: NSRange) { count += 1 }
        }
        let storage = MarkdownTextStorage(text: "# One\nbody\n")
        let recorder = Recorder()
        storage.addObserver(recorder)
        storage.setRevealRange(NSRange(location: 2, length: 0))
        recorder.count = 0
        storage.setRevealRange(NSRange(location: 4, length: 0))
        XCTAssertEqual(recorder.count, 0)
    }

    /// Typing on the revealed paragraph must not collapse the markers under
    /// the caret: the rescan reads the reveal from the storage.
    func testTypingOnTheRevealedParagraphKeepsItsMarkersVisible() throws {
        let storage = MarkdownTextStorage(text: "# Title\nBody\n")
        storage.setRevealRange(NSRange(location: 7, length: 0))
        storage.replaceCharacters(in: NSRange(location: 7, length: 0), with: "!")
        let marker = try XCTUnwrap(font(storage, at: 0))
        XCTAssertGreaterThan(marker.pointSize, LayoutAttributeStyler.hiddenMarkerSize)
    }
}
