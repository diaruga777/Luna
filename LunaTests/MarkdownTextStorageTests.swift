//
//  MarkdownTextStorageTests.swift
//  LunaTests
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
}
