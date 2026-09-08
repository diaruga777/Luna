//
//  NoteCaptureSplitterTests.swift
//  LunaWriterTests
//

import Foundation
import XCTest
@testable import LunaWriterStorage
import LunaWriterModels

final class NoteCaptureSplitterTests: XCTestCase {

    func testAShortCaptureStaysOneNote() {
        let text = "Remember to ask about the roof."
        XCTAssertEqual(NoteCaptureSplitter.split(text), [text])
    }

    func testAnEmptyCaptureBecomesNoNotes() {
        XCTAssertEqual(NoteCaptureSplitter.split("   \n\n  "), [])
    }

    func testALongCaptureSplitsOnTheBlankLinesTheWriterAlreadyMade() {
        let first = paragraph("roof", sentences: 4)
        let second = paragraph("garden", sentences: 4)
        let third = paragraph("kitchen", sentences: 4)

        let notes = NoteCaptureSplitter.split([first, second, third].joined(separator: "\n\n"))

        XCTAssertEqual(notes, [first, second, third])
        assertNothingDropped([first, second, third].joined(separator: "\n\n"), notes)
    }

    func testAFragmentJoinsThePreviousNote() {
        let long = paragraph("roof", sentences: 5)
        let fragment = "And a footnote."
        let another = paragraph("garden", sentences: 5)

        let notes = NoteCaptureSplitter.split([long, fragment, another].joined(separator: "\n\n"))

        XCTAssertEqual(notes.count, 2)
        XCTAssertTrue(notes[0].hasSuffix(fragment))
        XCTAssertEqual(notes[1], another)
    }

    func testALeadingFragmentJoinsTheNoteItIntroduces() {
        let lead = "Roof notes:"
        let long = paragraph("roof", sentences: 10)

        let notes = NoteCaptureSplitter.split([lead, long].joined(separator: "\n\n"))

        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].hasPrefix(lead))
        assertNothingDropped([lead, long].joined(separator: "\n\n"), notes)
    }

    func testAnOverlongParagraphIsPackedFromItsSentences() {
        let long = paragraph("roof", sentences: 40)
        XCTAssertGreaterThan(long.count, NoteCaptureSplitter.packTarget)

        let notes = NoteCaptureSplitter.split(long)

        XCTAssertGreaterThan(notes.count, 1)
        for note in notes {
            XCTAssertLessThanOrEqual(
                note.count, NoteCaptureSplitter.packTarget + 200,
                "a packed note should sit near the target, not run past it")
        }
        assertNothingDropped(long, notes)
    }

    func testACaptureNeverBecomesMoreThanTenNotesAndNothingIsLost() {
        let paragraphs = (1...18).map { paragraph("topic\($0)", sentences: 3) }
        let capture = paragraphs.joined(separator: "\n\n")

        let notes = NoteCaptureSplitter.split(capture)

        XCTAssertEqual(notes.count, NoteCaptureSplitter.maximumSubNotes)
        assertNothingDropped(capture, notes)
    }

    func testOneEnormousParagraphIsCutAtTheHardCap() {
        let capture = Array(repeating: "wordy", count: 3_000).joined(separator: " ")
        XCTAssertGreaterThan(capture.count, NoteCaptureSplitter.maximumNoteLength * 2)

        let notes = NoteCaptureSplitter.split(capture)

        XCTAssertGreaterThan(notes.count, 1)
        for note in notes {
            XCTAssertLessThanOrEqual(note.count, NoteCaptureSplitter.maximumNoteLength)
        }
        assertNothingDropped(capture, notes)
    }

    // MARK: - Explicit phrases

    func testTheExplicitPhrasesAskForANewSheetAndHandBackTheTitle() {
        XCTAssertEqual(
            ExplicitNewDocumentPhrase.match("new document: Bread notes"), "Bread notes")
        XCTAssertEqual(ExplicitNewDocumentPhrase.match("New Doc: Bread notes"), "Bread notes")
        XCTAssertEqual(ExplicitNewDocumentPhrase.match("new idea: Bread notes"), "Bread notes")
        XCTAssertEqual(ExplicitNewDocumentPhrase.match("fresh concept: Bread"), "Bread")
        XCTAssertEqual(
            ExplicitNewDocumentPhrase.match("start a new document about bread"), "about bread")
        XCTAssertEqual(
            ExplicitNewDocumentPhrase.match("create a new document — bread"), "bread")
    }

    func testTheLongerPhraseWinsSoTheVerbIsNotLeftInTheTitle() {
        XCTAssertEqual(ExplicitNewDocumentPhrase.match("create a new document: Bread"), "Bread")
    }

    func testAPhraseInTheMiddleOfACaptureIsNotACommand() {
        XCTAssertNil(ExplicitNewDocumentPhrase.match("I should start a new document for this"))
        XCTAssertNil(ExplicitNewDocumentPhrase.match("bread notes"))
    }

    func testAPhraseWithNothingAfterItAsksForAnUntitledSheet() {
        XCTAssertEqual(ExplicitNewDocumentPhrase.match("new document:"), "")
    }

    // MARK: - Titles

    func testATitleTakesTheFirstWordsAndRaisesOnlyTheirFirstLetter() {
        XCTAssertEqual(
            TitleFromWords.make("buy more olive oil for the kitchen tomorrow", count: 6),
            "Buy More Olive Oil For The")
        XCTAssertEqual(
            TitleFromWords.make("the iPhone battery drains", count: 6),
            "The iPhone Battery Drains",
            "a word the writer already capitalised keeps its shape")
    }

    func testATitleFromPunctuationAloneFallsBackRatherThanBeingBlank() {
        XCTAssertFalse(TitleFromWords.make("!!! ??? ...", count: 6).isEmpty)
    }

    // MARK: - Helpers

    private func paragraph(_ subject: String, sentences: Int) -> String {
        (1...sentences)
            .map { "The \(subject) needs attention in the \($0) week of the year." }
            .joined(separator: " ")
    }

    /// Every non-blank character of the capture survives, in order.
    private func assertNothingDropped(
        _ capture: String, _ notes: [String], file: StaticString = #filePath, line: UInt = #line
    ) {
        let squash: (String) -> String = { $0.filter { !$0.isWhitespace } }
        XCTAssertEqual(
            squash(notes.joined()), squash(capture), file: file, line: line)
    }
}
