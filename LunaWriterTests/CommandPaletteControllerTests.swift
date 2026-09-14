//
//  CommandPaletteControllerTests.swift
//  LunaWriterTests
//

import XCTest
import UIKit
@testable import LunaWriterEditor
import LunaWriterModels
import LunaWriterStorage

/// Answers whatever the test scripted, and remembers what was asked.
private final class FakeNoteIndex: NoteIndexing {
    var answers: [NoteHit] = []
    var queries: [NoteQuery] = []
    var indexed: [WriterNote] = []

    func index(_ note: WriterNote) throws { indexed.append(note) }
    func remove(_ id: NoteID) throws {}
    func search(_ query: NoteQuery) throws -> [NoteHit] {
        queries.append(query)
        if case .all = query.scope { return [] }
        return answers
    }
    func related(to windowText: String, in document: DocumentID, limit: Int) throws -> [NoteHit] { [] }
    func rebuild() throws {}
}

private final class FakeNoteStore: NoteStoring {
    var notes: [NoteID: WriterNote] = [:]
    var inserted: [WriterNote] = []
    var attachments: [(NoteID, DocumentID, NoteAttachment)] = []

    func notes(for document: DocumentID) throws -> [WriterNote] { Array(notes.values) }
    func unattachedNotes() throws -> [WriterNote] { [] }
    func note(_ id: NoteID) throws -> WriterNote? { notes[id] }
    func insert(_ note: WriterNote) throws {
        notes[note.id] = note
        inserted.append(note)
    }
    func update(_ note: WriterNote) throws { notes[note.id] = note }
    func delete(_ id: NoteID) throws { notes[id] = nil }
    func attach(_ id: NoteID, to document: DocumentID, attachment: NoteAttachment) throws {
        attachments.append((id, document, attachment))
    }
    func detach(_ id: NoteID, from document: DocumentID) throws {}
}

private final class PaletteRecorder: CommandPaletteControllerDelegate {
    var states: [PaletteState] = []
    var results: [[NoteHit]] = []
    var peeked: [WriterNote] = []
    var created: [WriterNote] = []
    var ended = 0

    func commandPalette(_ controller: CommandPaletteController, didChange state: PaletteState) {
        states.append(state)
    }
    func commandPalette(_ controller: CommandPaletteController, didUpdate results: [NoteHit], query: String) {
        self.results.append(results)
    }
    func commandPalette(_ controller: CommandPaletteController, didRequestPeek note: WriterNote) {
        peeked.append(note)
    }
    func commandPalette(_ controller: CommandPaletteController, didCreate note: WriterNote, from markerRect: CGRect) {
        created.append(note)
    }
    func commandPaletteDidEnd(_ controller: CommandPaletteController) { ended += 1 }
}

final class CommandPaletteControllerTests: XCTestCase {

    private var textView: WriterTextView!
    private var index: FakeNoteIndex!
    private var store: FakeNoteStore!
    private var recorder: PaletteRecorder!
    private var controller: CommandPaletteController!
    private let documentID = DocumentID()

    override func setUp() {
        super.setUp()
        let storage = MarkdownTextStorage(text: "")
        textView = WriterTextView(metrics: EditorMetrics(), textStorage: storage)
        textView.frame = CGRect(x: 0, y: 0, width: 375, height: 600)
        index = FakeNoteIndex()
        store = FakeNoteStore()
        recorder = PaletteRecorder()
        controller = CommandPaletteController(
            noteIndex: index, noteStore: store, documentID: documentID, debounce: 0.01)
        controller.textView = textView
        controller.delegate = recorder
    }

    override func tearDown() {
        controller = nil
        textView = nil
        super.tearDown()
    }

    /// Types one character at a time through the same hooks the text view calls.
    private func type(_ string: String) {
        for character in string {
            let piece = String(character)
            let range = textView.selectedRange
            guard controller.textView(textView, shouldChangeTextIn: range, replacementText: piece) else { continue }
            textView.textStorage.replaceCharacters(in: range, with: piece)
            textView.selectedRange = NSRange(location: range.location + (piece as NSString).length, length: 0)
            controller.textViewDidChange(textView)
            controller.textViewDidChangeSelection(textView)
        }
    }

    private func moveCaret(to location: Int) {
        textView.selectedRange = NSRange(location: location, length: 0)
        controller.textViewDidChangeSelection(textView)
    }

    private func waitUntil(
        _ condition: () -> Bool, timeout: TimeInterval = 2,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "condition never held", file: file, line: line)
    }

    private func makeHit(_ text: String) -> (WriterNote, NoteHit) {
        let note = WriterNote(documentIDs: [documentID], text: text, source: .typed)
        store.notes[note.id] = note
        return (note, NoteHit(noteID: note.id, score: 0.9, snippet: text))
    }

    // MARK: - Arming

    func testAtTheStartOfTheSheetArmsAndKeepsTheCharacter() throws {
        type("@")
        XCTAssertEqual(textView.text, "@")
        XCTAssertEqual(controller.state, .armed(marker: 0))
    }

    func testAfterASpaceArms() throws {
        type("hello @")
        XCTAssertEqual(controller.state.marker, 6)
    }

    func testInsideAWordDoesNotArm() throws {
        type("mail@")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(textView.text, "mail@")
    }

    func testAfterPunctuationArms() throws {
        type("(@")
        XCTAssertEqual(controller.state.marker, 1)
    }

    // MARK: - Query tracking

    func testTypingAfterTheMarkerBecomesTheQuery() throws {
        type("@octo")
        XCTAssertEqual(controller.state, .querying(marker: 0, query: "octo"))
    }

    func testDeletingBackToTheMarkerKeepsTheOverlayArmed() throws {
        type("@ab")
        textView.textStorage.replaceCharacters(in: NSRange(location: 2, length: 1), with: "")
        textView.selectedRange = NSRange(location: 2, length: 0)
        controller.textViewDidChange(textView)
        XCTAssertEqual(controller.state, .querying(marker: 0, query: "a"))
    }

    func testDeletingTheMarkerEndsIt() throws {
        type("@ab")
        textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "")
        textView.selectedRange = NSRange(location: 0, length: 0)
        controller.textViewDidChange(textView)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(recorder.ended, 1)
    }

    // MARK: - Cancelling

    func testANewlineEndsIt() throws {
        type("@note\n")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(textView.text.hasSuffix("\n"), "the typed text stays")
    }

    func testMoreThanSixWordsEndsIt() throws {
        type("@one two three four five six")
        XCTAssertTrue(controller.state.isActive)
        type(" seven")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(textView.text, "@one two three four five six seven")
    }

    func testADoubleSpaceEndsIt() throws {
        type("@note ")
        XCTAssertTrue(controller.state.isActive)
        type(" ")
        XCTAssertEqual(controller.state, .idle)
    }

    func testMovingTheCaretOutOfTheQueryEndsIt() throws {
        type("word @note")
        XCTAssertTrue(controller.state.isActive)
        moveCaret(to: 2)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(textView.text, "word @note")
    }

    func testDismissLeavesTheTypedText() throws {
        type("@note")
        controller.dismiss()
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(textView.text, "@note")
    }

    // MARK: - Searching

    func testTheQueryIsSearchedInThisSheetFirstWithAPrefixOnTheLastToken() throws {
        let (_, hit) = makeHit("octopus tank")
        index.answers = [hit]
        type("@octo")
        waitUntil { !self.controller.results.isEmpty }
        XCTAssertEqual(controller.results.map { $0.noteID }, [hit.noteID])
        let first = try XCTUnwrap(index.queries.first)
        XCTAssertEqual(first.scope, .document(documentID))
        XCTAssertTrue(first.prefixMatchesLastToken)
        XCTAssertEqual(first.limit, CommandPaletteController.resultLimit)
        XCTAssertTrue(index.queries.contains { $0.scope == .all })
    }

    func testTheRowsAreTheResultsPlusTheNewNoteRow() throws {
        let (_, hit) = makeHit("octopus tank")
        index.answers = [hit]
        type("@octo")
        waitUntil { self.controller.rowCount == 2 }
        XCTAssertEqual(controller.rowCount, 2)
    }

    // MARK: - Peek

    func testReturnOnAResultPeeksTheNoteAndLeavesTheQuery() throws {
        let (note, hit) = makeHit("octopus tank")
        index.answers = [hit]
        type("@octo")
        waitUntil { !self.controller.results.isEmpty }
        controller.commitHighlighted()
        XCTAssertEqual(recorder.peeked.map { $0.id }, [note.id])
        XCTAssertEqual(textView.text, "@octo", "the overlay never inserts note text")
        XCTAssertTrue(controller.isPeeking)
    }

    func testClosingThePeekRemovesTheQueryAndRestoresTheCaret() throws {
        let (_, hit) = makeHit("octopus tank")
        index.answers = [hit]
        type("draft @octo")
        waitUntil { !self.controller.results.isEmpty }
        controller.commitHighlighted()
        controller.closePeek()
        XCTAssertEqual(textView.text, "draft ")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 6, length: 0))
        XCTAssertEqual(controller.state, .idle)
    }

    /// `refresh(_:)` ignores every edit while a peek is up, on purpose — the
    /// query stays put so the peeked note doesn't flicker. If an edit
    /// elsewhere in the document shifted the "@" in the meantime, closing
    /// the peek must notice and leave the text alone rather than remove
    /// characters at the stale, no-longer-correct offset.
    func testClosingAPeekAfterAnEarlierEditShiftedTheMarkerLeavesTheTextAlone() throws {
        let (_, hit) = makeHit("octopus tank")
        index.answers = [hit]
        type("draft @octo")
        waitUntil { !self.controller.results.isEmpty }
        controller.commitHighlighted()

        textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "PREFIX ")
        textView.selectedRange = NSRange(location: (textView.text as NSString).length, length: 0)

        controller.closePeek()

        XCTAssertEqual(textView.text, "PREFIX draft @octo")
        XCTAssertEqual(controller.state, .idle)
    }

    // MARK: - Create

    func testReturnWithNoResultsMakesANoteFromTheQuery() throws {
        type("draft @a new idea")
        waitUntil { self.recorder.results.count > 0 }
        controller.commitHighlighted()
        // The store write runs off the keystroke's own thread now.
        waitUntil { self.recorder.created.count > 0 }

        XCTAssertEqual(store.inserted.count, 1)
        let note = try XCTUnwrap(store.inserted.first)
        XCTAssertEqual(note.text, "a new idea")
        XCTAssertEqual(note.source, .mention)
        XCTAssertEqual(note.documentIDs, [documentID])
        XCTAssertEqual(note.anchor?.start, 6)
        XCTAssertEqual(store.attachments.map { $0.2 }, [NoteAttachment.mention])
        XCTAssertEqual(index.indexed.count, 1)
        XCTAssertEqual(textView.text, "draft ", "the @query is taken out of the sheet")
        XCTAssertEqual(recorder.created.count, 1)
        XCTAssertEqual(controller.state, .idle)
    }

    func testTheLastRowMakesANoteEvenWithResults() throws {
        let (_, hit) = makeHit("octopus tank")
        index.answers = [hit]
        type("@octo")
        waitUntil { !self.controller.results.isEmpty }
        controller.moveHighlight(by: 1)
        XCTAssertEqual(controller.highlightedIndex, 1)
        controller.commitHighlighted()
        waitUntil { self.recorder.created.count > 0 }
        XCTAssertEqual(store.inserted.count, 1)
        XCTAssertEqual(recorder.peeked.count, 0)
    }

    func testAnEmptyQueryMakesNothing() throws {
        type("@")
        controller.commitHighlighted()
        XCTAssertTrue(store.inserted.isEmpty)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(textView.text, "@")
    }

    func testTheHighlightNeverLeavesTheRows() throws {
        type("@idea")
        controller.moveHighlight(by: -5)
        XCTAssertEqual(controller.highlightedIndex, 0)
        controller.moveHighlight(by: 9)
        XCTAssertEqual(controller.highlightedIndex, controller.rowCount - 1)
    }
}
