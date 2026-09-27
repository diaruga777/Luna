//
//  CommandPaletteControllerTests.swift
//  LunaWriterTests
//

import XCTest
import UIKit
@testable import LunaWriterEditor
import LunaModels
import LunaWriterModels
import LunaWriterStorage
import LunaWriterText

/// Answers whatever the test scripted, and remembers what was asked.
private final class FakeNoteIndex: NoteIndexing {
    var answers: [NoteHit] = []
    var globalAnswers: [NoteHit] = []
    var queries: [NoteQuery] = []
    var indexed: [WriterNote] = []

    func index(_ note: WriterNote) throws { indexed.append(note) }
    func remove(_ id: NoteID) throws {}
    func search(_ query: NoteQuery) throws -> [NoteHit] {
        queries.append(query)
        if case .all = query.scope { return globalAnswers }
        return answers
    }
    func related(to windowText: String, in document: DocumentID, limit: Int) throws -> [NoteHit] { [] }
    func rebuild() throws {}
}

private final class FakeNoteStore: NoteStoring {
    var notes: [NoteID: WriterNote] = [:]
    var inserted: [WriterNote] = []
    var attachments: [(NoteID, DocumentID, NoteAttachment)] = []

    func allNotes() throws -> [WriterNote] { Array(notes.values) }
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

private final class ScriptedThesaurus: WordThesaurus {
    var isAvailable = true
    var answers: [String: [String]] = [:]
    var asked: [String] = []
    func matches(for word: String, limit: Int) -> [(word: String, score: Double)] {
        asked.append(word)
        return (answers[word] ?? []).prefix(limit).enumerated().map {
            ($0.element, 0.75 - Double($0.offset) * 0.05)
        }
    }
}

private final class PaletteRecorder: CommandPaletteControllerDelegate {
    var states: [PaletteState] = []
    var rowUpdates: [[PaletteRow]] = []
    var peeked: [WriterNote] = []
    var created: [WriterNote] = []
    var chapterRequests = 0
    var ended = 0

    func commandPalette(_ controller: CommandPaletteController, didChange state: PaletteState) {
        states.append(state)
    }
    func commandPalette(_ controller: CommandPaletteController, didUpdate rows: [PaletteRow]) {
        rowUpdates.append(rows)
    }
    func commandPalette(_ controller: CommandPaletteController, didRequestPeek note: WriterNote) {
        peeked.append(note)
    }
    func commandPalette(_ controller: CommandPaletteController, didCreate note: WriterNote, from markerRect: CGRect) {
        created.append(note)
    }
    func commandPaletteDidRequestNewChapter(_ controller: CommandPaletteController) { chapterRequests += 1 }
    func commandPaletteDidEnd(_ controller: CommandPaletteController) { ended += 1 }
}

final class CommandPaletteControllerTests: XCTestCase {

    private var textView: WriterTextView!
    private var index: FakeNoteIndex!
    private var store: FakeNoteStore!
    private var thesaurus: ScriptedThesaurus!
    private var recorder: PaletteRecorder!
    private var controller: CommandPaletteController!
    private let documentID = DocumentID()
    /// The clock the double-space trigger reads. Tests move it by hand.
    private var clock: TimeInterval = 1000

    override func setUp() {
        super.setUp()
        let storage = MarkdownTextStorage(text: "")
        textView = WriterTextView(metrics: EditorMetrics(), textStorage: storage)
        textView.frame = CGRect(x: 0, y: 0, width: 375, height: 600)
        index = FakeNoteIndex()
        store = FakeNoteStore()
        thesaurus = ScriptedThesaurus()
        recorder = PaletteRecorder()
        controller = makeController(thesaurus: thesaurus)
    }

    private func makeController(thesaurus: WordThesaurus?) -> CommandPaletteController {
        let controller = CommandPaletteController(
            noteIndex: index, noteStore: store, documentID: documentID, thesaurus: thesaurus,
            debounce: 0.01, now: { [unowned self] in self.clock })
        controller.trigger = .atSign
        controller.textView = textView
        controller.delegate = recorder
        return controller
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

    /// A space, then another one `after` seconds later.
    private func typeDoubleSpace(after interval: TimeInterval) {
        type(" ")
        clock += interval
        type(" ")
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

    private var actions: [PaletteAction] { controller.rows.map(\.action) }

    // MARK: - Arming with "@"

    func testAtTheStartOfTheSheetArmsAndKeepsTheCharacter() throws {
        type("@")
        XCTAssertEqual(textView.text, "@")
        XCTAssertEqual(controller.state, .armed(marker: 0))
        XCTAssertEqual(controller.markerLength, 1)
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

    func testAnAtSignDoesNothingWhenDoubleSpaceIsTheTrigger() throws {
        controller.trigger = .doubleSpace
        type("hello @")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(textView.text, "hello @")
    }

    // MARK: - Arming with a double space

    func testAFastDoubleSpaceOpensAfterTheFirstSpaceAndSwallowsTheSecond() throws {
        controller.trigger = .doubleSpace
        type("hello")
        typeDoubleSpace(after: 0.1)
        XCTAssertEqual(textView.text, "hello ", "the second space is not typed")
        XCTAssertEqual(controller.state, .armed(marker: 6))
        XCTAssertEqual(controller.markerLength, 0)
    }

    func testASlowDoubleSpaceStaysText() throws {
        controller.trigger = .doubleSpace
        type("hello")
        typeDoubleSpace(after: CommandPaletteController.doubleSpaceInterval + 0.5)
        XCTAssertEqual(textView.text, "hello  ")
        XCTAssertEqual(controller.state, .idle)
    }

    func testAKeystrokeBetweenTheTwoSpacesResetsTheClock() throws {
        controller.trigger = .doubleSpace
        type("a b")
        clock += 0.05
        type(" ")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(textView.text, "a b ")
    }

    func testTheSystemPeriodShortcutIsRefusedWhenItIsAFastDoubleSpace() throws {
        controller.trigger = .doubleSpace
        type("hello ")
        clock += 0.1
        let allowed = controller.textView(
            textView, shouldChangeTextIn: NSRange(location: 5, length: 1), replacementText: ". ")
        XCTAssertFalse(allowed, "no period is typed")
        XCTAssertEqual(controller.state, .armed(marker: 6))
    }

    func testADoubleSpaceDoesNothingWhenTheAtSignIsTheTrigger() throws {
        type("hello")
        typeDoubleSpace(after: 0.1)
        XCTAssertEqual(textView.text, "hello  ")
        XCTAssertEqual(controller.state, .idle)
    }

    func testTypingAfterADoubleSpaceIsTheQuery() throws {
        controller.trigger = .doubleSpace
        type("hello")
        typeDoubleSpace(after: 0.1)
        type("sym")
        XCTAssertEqual(controller.state, .querying(marker: 6, query: "sym"))
        XCTAssertEqual(textView.text, "hello sym")
    }

    func testBackspaceOnAnEmptyDoubleSpacePaletteClosesItAndDeletesNothing() throws {
        controller.trigger = .doubleSpace
        type("hello")
        typeDoubleSpace(after: 0.1)
        let allowed = controller.textView(
            textView, shouldChangeTextIn: NSRange(location: 5, length: 1), replacementText: "")
        XCTAssertFalse(allowed)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(textView.text, "hello ")
        XCTAssertEqual(recorder.ended, 1)
    }

    func testBackspaceOnTheAtSignIsAllowedAndEndsThePalette() throws {
        type("@")
        let allowed = controller.textView(
            textView, shouldChangeTextIn: NSRange(location: 0, length: 1), replacementText: "")
        XCTAssertTrue(allowed, "the @ itself is deleted like any character")
        textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 1), with: "")
        textView.selectedRange = NSRange(location: 0, length: 0)
        controller.textViewDidChange(textView)
        XCTAssertEqual(controller.state, .idle)
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

    func testADoubleSpaceInsideTheQueryEndsIt() throws {
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

    // MARK: - Searching notes

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

    func testTheRowsAreTheNoteHitsPlusTheNewNoteRow() throws {
        let (_, hit) = makeHit("octopus tank")
        index.answers = [hit]
        type("@octo")
        waitUntil { self.controller.rowCount == 2 }
        XCTAssertEqual(actions, [.peekNote(hit.noteID), .createNote])
    }

    func testAnEmptyPaletteHasNoSuggestions() throws {
        type("@")
        XCTAssertTrue(actions.isEmpty)
        XCTAssertNil(controller.highlightedIndex)
        XCTAssertTrue(index.queries.isEmpty)
        XCTAssertTrue(thesaurus.asked.isEmpty)
    }

    func testClearingAQueryImmediatelyRemovesItsRows() throws {
        type("@epsilon")
        waitUntil { self.actions.contains(.insertText("ε")) }
        textView.textStorage.replaceCharacters(in: NSRange(location: 1, length: 7), with: "")
        textView.selectedRange = NSRange(location: 1, length: 0)
        controller.textViewDidChange(textView)
        XCTAssertTrue(actions.isEmpty)
        XCTAssertTrue(controller.results.isEmpty)
        XCTAssertNil(controller.highlightedIndex)
        type(" ")
        XCTAssertTrue(actions.isEmpty, "whitespace also has no suggestions")
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
        waitUntil { self.actions == [.createNote] }
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
        waitUntil { self.controller.rowCount == 2 }
        controller.moveHighlight(by: 1)
        XCTAssertEqual(controller.highlightedIndex, 1)
        controller.commitHighlighted()
        waitUntil { self.recorder.created.count > 0 }
        XCTAssertEqual(store.inserted.count, 1)
        XCTAssertEqual(recorder.peeked.count, 0)
    }

    func testNewNoteWithAnEmptyQueryMakesNothing() throws {
        type("@")
        controller.highlightRow(controller.rowCount - 1)
        controller.commitHighlighted()
        XCTAssertTrue(store.inserted.isEmpty)
        XCTAssertEqual(controller.state, .armed(marker: 0))
        XCTAssertNil(controller.highlightedIndex)
        XCTAssertEqual(textView.text, "@")
    }

    func testTheHighlightNeverLeavesTheRows() throws {
        type("@a new idea")
        waitUntil { self.actions == [.createNote] }
        controller.moveHighlight(by: 1)
        XCTAssertEqual(controller.highlightedIndex, 0, "the first press lands on the first row")
        controller.moveHighlight(by: 9)
        XCTAssertEqual(controller.highlightedIndex, controller.rowCount - 1)
        controller.moveHighlight(by: -99)
        XCTAssertEqual(controller.highlightedIndex, 0)
    }

    // MARK: - Commands

    func testPlainSymbolQueryInsertsTheCharacter() throws {
        type("@epsilon")
        waitUntil { self.actions.first == .insertText("ε") }
        XCTAssertEqual(index.queries.last?.text, "epsilon")
        XCTAssertEqual(thesaurus.asked.last, "epsilon")
        XCTAssertEqual(actions.last, .createNote)
        controller.commitHighlighted()
        XCTAssertEqual(textView.text, "ε")
        XCTAssertEqual(textView.selectedRange, NSRange(location: 1, length: 0))
        XCTAssertEqual(controller.state, .idle)
    }

    func testASymbolInsertedFromADoubleSpacePaletteFollowsTheFirstSpace() throws {
        controller.trigger = .doubleSpace
        type("hello")
        typeDoubleSpace(after: 0.1)
        XCTAssertTrue(actions.isEmpty)
        type("emdash")
        waitUntil { self.actions.first == .insertText("—") }
        controller.commitHighlighted()
        XCTAssertEqual(textView.text, "hello —")
        XCTAssertEqual(controller.state, .idle)
    }

    func testUnknownQueryOffersOnlyNoteCapture() throws {
        type("@zzqxv")
        waitUntil { self.actions == [.createNote] }
    }

    func testFormerPrefixIsOrdinaryTextAndStillSearchesNotesAndSynonyms() throws {
        let (_, hit) = makeHit("symbol epsilon")
        index.answers = [hit]
        thesaurus.answers["symbol epsilon"] = ["alternative"]
        type("@symbol epsilon")
        waitUntil { self.actions.contains(.peekNote(hit.noteID)) }
        XCTAssertEqual(index.queries.last?.text, "symbol epsilon")
        XCTAssertEqual(thesaurus.asked.last, "symbol epsilon")
        XCTAssertTrue(actions.contains(.insertText("alternative")))
        XCTAssertEqual(actions.last, .createNote)
    }

    func testThesaurusUsesPlainQueryAndInsertsTheChosenWord() throws {
        thesaurus.answers["happy"] = ["glad", "cheerful", "joyful"]
        type("@happy")
        waitUntil { self.actions.contains(.insertText("cheerful")) }
        XCTAssertEqual(thesaurus.asked.last, "happy")
        XCTAssertEqual(index.queries.last?.text, "happy")
        controller.highlightRow(try XCTUnwrap(actions.firstIndex(of: .insertText("cheerful"))))
        controller.commitHighlighted()
        XCTAssertEqual(textView.text, "cheerful")
        XCTAssertEqual(controller.state, .idle)
    }

    func testMissingThesaurusDoesNotAddMessageRows() throws {
        controller = makeController(thesaurus: nil)
        type("@epsilon")
        waitUntil { self.actions.first == .insertText("ε") }
        XCTAssertFalse(actions.contains(.none))
        XCTAssertEqual(actions.last, .createNote)
    }

    func testEveryDomainIsMergedByScore() throws {
        let local = NoteHit(noteID: NoteID(), score: 0.45, snippet: "loosely related")
        let global = NoteHit(noteID: NoteID(), score: 0.97, snippet: "strongly related")
        index.answers = [local]
        index.globalAnswers = [global, local]
        thesaurus.answers["epsilon"] = ["alternative", "another"]
        type("@epsilon")
        waitUntil { self.actions.contains(.insertText("alternative")) }
        let scores = controller.rows.dropLast().map(\.score)
        XCTAssertEqual(scores, scores.sorted(by: >))
        XCTAssertEqual(actions.first, .insertText("ε"), "exact symbol outranks weaker notes and synonyms")
        XCTAssertLessThan(try XCTUnwrap(actions.firstIndex(of: .peekNote(global.noteID))),
                          try XCTUnwrap(actions.firstIndex(of: .insertText("alternative"))))
        XCTAssertLessThan(try XCTUnwrap(actions.firstIndex(of: .insertText("alternative"))),
                          try XCTUnwrap(actions.firstIndex(of: .peekNote(local.noteID))))
        XCTAssertEqual(actions.filter { $0 == .peekNote(local.noteID) }.count, 1)
    }

    func testStrongerNoteOutranksPartialCommandMatch() throws {
        let (_, hit) = makeHit("new chap")
        index.answers = [hit]
        type("@new chap")
        waitUntil { self.actions.contains(.startChapter) }
        XCTAssertEqual(actions.first, .peekNote(hit.noteID))
    }

    func testResultLimitIsAppliedAfterMergingDomainsByStrength() throws {
        index.answers = (0..<6).map {
            NoteHit(noteID: NoteID(), score: 0.2 + Double($0) * 0.01, snippet: "related note")
        }
        thesaurus.answers["arrow"] = ["direction", "pointer", "dart"]
        type("@arrow")
        waitUntil { self.actions.last == .createNote }
        XCTAssertEqual(PaletteRow.displayGroups(in: controller.rows).count, CommandPaletteController.resultLimit + 1)
        XCTAssertGreaterThan(controller.rowCount, CommandPaletteController.resultLimit + 1)
        XCTAssertEqual(actions.last, .createNote)
        XCTAssertTrue(actions.contains { if case .peekNote = $0 { return true }; return false },
                      "symbol tiles leave room for other result types")
        let scores = controller.rows.dropLast().map(\.score)
        XCTAssertEqual(scores, scores.sorted(by: >))
    }

    func testChangingTheQueryClearsThePreviousReturnActionBeforeSearchCompletes() throws {
        type("@epsilon")
        waitUntil { self.actions.first == .insertText("ε") }
        type("x")
        XCTAssertTrue(actions.isEmpty)
        XCTAssertNil(controller.highlightedIndex)
        XCTAssertTrue(pressReturn())
        XCTAssertEqual(textView.text, "@epsilonx")
    }

    func testFormattingWordsHaveNoFormattingActions() throws {
        for query in ["bold", "h2", "format", "code block", "italic"] {
            controller.dismiss()
            type(" @" + query)
            waitUntil { self.actions.last == .createNote }
            XCTAssertTrue(controller.rows.allSatisfy {
                ["character", "text.book.closed", "note.text", "plus.circle"].contains($0.symbolName)
            }, query)
        }
    }

    // MARK: - Return

    /// The caret's Return key, as the text view reports it.
    private func pressReturn() -> Bool {
        controller.textView(textView, shouldChangeTextIn: textView.selectedRange, replacementText: "\n")
    }

    func testAStrongFirstMatchIsHighlightedAndReturnRunsIt() throws {
        type("hello @emd")
        waitUntil { self.actions.first == .insertText("—") }
        XCTAssertEqual(controller.highlightedIndex, 0)
        XCTAssertGreaterThanOrEqual(controller.rows[0].score, CommandPaletteController.returnThreshold)
        XCTAssertFalse(pressReturn(), "Return is spent on the row, not typed")
        XCTAssertEqual(textView.text, "hello —")
        XCTAssertEqual(controller.state, .idle)
    }

    func testAWeakFirstMatchHighlightsNothingAndReturnTypesTheNewline() throws {
        type("Title @emdsh")
        waitUntil { self.actions.contains(.insertText("—")) }
        XCTAssertNil(controller.highlightedIndex)
        XCTAssertFalse(controller.commitHighlighted())
        XCTAssertTrue(pressReturn(), "the text view types its newline")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(textView.text, "Title @emdsh", "nothing was applied or removed")
    }

    func testAnEmptyPaletteHighlightsNothing() throws {
        type("@")
        XCTAssertNil(controller.highlightedIndex)
        XCTAssertTrue(pressReturn())
        XCTAssertEqual(controller.state, .idle)
    }

    func testWordsMatchingNothingElseMakeNewNoteTheReturnRow() throws {
        type("draft @a new idea")
        waitUntil { self.actions == [.createNote] }
        XCTAssertEqual(controller.highlightedIndex, 0)
    }

    func testAnArrowedChoiceStandsForTheSameQueryAndResetsWhenItChanges() throws {
        type("@emdash")
        waitUntil { self.actions.first == .insertText("—") && self.actions.count > 1 }
        controller.moveHighlight(by: 1)
        XCTAssertEqual(controller.highlightedIndex, 1)
        type("x")
        waitUntil { self.actions == [.createNote] }
        XCTAssertEqual(controller.highlightedIndex, 0, "a new query starts from its own default row")
    }

    func testTheFirstArrowPressLandsOnAnEndRow() throws {
        type("@emdsh")
        waitUntil { self.actions.contains(.insertText("—")) }
        controller.moveHighlight(by: -1)
        XCTAssertEqual(controller.highlightedIndex, controller.rowCount - 1)
        controller.moveHighlight(by: 1)
        XCTAssertEqual(controller.highlightedIndex, controller.rowCount - 1, "clamped at the end")
        controller.dismiss()
        type(" @emdsh")
        waitUntil { self.actions.contains(.insertText("—")) }
        controller.moveHighlight(by: 1)
        XCTAssertEqual(controller.highlightedIndex, 0)
    }

    func testNewChapterRemovesTheQueryClosesAndTellsTheDelegate() throws {
        type("one two @new chap")
        waitUntil { self.actions.first == .startChapter }
        controller.commitHighlighted()
        XCTAssertEqual(textView.text, "one two ")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertEqual(recorder.chapterRequests, 1)
    }
}
