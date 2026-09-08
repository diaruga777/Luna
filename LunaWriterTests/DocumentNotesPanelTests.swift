//
//  DocumentNotesPanelTests.swift
//  LunaWriterTests
//

import UIKit
import XCTest
@testable import LunaWriterLibraryUI
import LunaWriterModels
import LunaWriterStorage

final class DocumentNotesPanelTests: XCTestCase {

    @MainActor
    func testNotesOrderByRecencyWithNoRelevanceScores() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")

        let older = WriterNote(documentIDs: [document.id], text: "Older", createdAt: Date().addingTimeInterval(-100), updatedAt: Date().addingTimeInterval(-100))
        let newer = WriterNote(documentIDs: [document.id], text: "Newer", createdAt: Date(), updatedAt: Date())
        try stack.library.insert(older)
        try stack.library.insert(newer)
        try stack.library.attach(older.id, to: document.id, attachment: .manual)
        try stack.library.attach(newer.id, to: document.id, attachment: .manual)

        let panel = DocumentNotesPanelViewController(
            library: stack.library, notesStore: stack.library, textStore: stack.textStore, document: document)
        layoutWriterScreen(panel)

        XCTAssertEqual(panel.rows.map(\.id), [newer.id, older.id])
    }

    @MainActor
    func testTappingAnAnchoredRowFocusesTheEditor() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        var document = try stack.library.createDocument(in: group.id, title: "Sheet")
        try stack.textStore.saveText("The quick brown fox jumps.", for: &document)

        let anchor = TextAnchor(start: 4, end: 9, exact: "quick")
        let note = WriterNote(documentIDs: [document.id], text: "About the fox", anchor: anchor)
        try stack.library.insert(note)
        try stack.library.attach(note.id, to: document.id, attachment: .manual)

        let panel = DocumentNotesPanelViewController(
            library: stack.library, notesStore: stack.library, textStore: stack.textStore, document: document)
        let editor = FakeDocumentEditor(document: document)
        panel.editor = editor
        layoutWriterScreen(panel)

        panel.selectNote(at: 0)
        XCTAssertEqual(editor.focusedAnchors, [anchor])
    }

    @MainActor
    func testComposingANoteAttachesItToTheOpenSheet() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")

        let panel = DocumentNotesPanelViewController(
            library: stack.library, notesStore: stack.library, textStore: stack.textStore, document: document)
        layoutWriterScreen(panel)

        panel.composeField.text = "A fresh thought\nAnd another line"
        let saved = expectation(description: "note saved")
        panel.saveDraft { success in XCTAssertTrue(success); saved.fulfill() }
        wait(for: [saved], timeout: 3)
        let note = try XCTUnwrap(panel.rows.first)
        XCTAssertEqual(note.text, "A fresh thought\nAnd another line")
        XCTAssertEqual(panel.composeField.text, "")
        XCTAssertTrue(try stack.library.notes(for: document.id).contains { $0.id == note.id })
        XCTAssertTrue(panel.rows.contains { $0.id == note.id })
    }

    @MainActor
    func testEditingANoteKeepsItsIdentityAndUpdatesSearch() throws {
        let stack = try makeWriterStack()
        let document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Draft")
        let note = WriterNote(documentIDs: [document.id], text: "Old thought")
        try stack.library.insert(note)
        let panel = DocumentNotesPanelViewController(library: stack.library, notesStore: stack.library,
            textStore: stack.textStore, document: document)
        layoutWriterScreen(panel)
        panel.selectNote(at: 0)
        XCTAssertEqual(panel.composeField.text, note.text)
        panel.composeField.text = "Updated thought\nWith another line"
        let saved = expectation(description: "note updated")
        panel.saveDraft { success in XCTAssertTrue(success); saved.fulfill() }
        wait(for: [saved], timeout: 3)
        XCTAssertEqual(try stack.library.notes(for: document.id).map(\.id), [note.id])
        XCTAssertEqual(try stack.library.note(note.id)?.text, "Updated thought\nWith another line")
        XCTAssertEqual(try stack.noteIndex.search(NoteQuery(text: "Updated")).first?.noteID, note.id)
    }

    @MainActor
    func testAFailedSaveKeepsTheDraftForRetry() throws {
        let stack = try makeWriterStack()
        let document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Draft")
        let panel = DocumentNotesPanelViewController(library: stack.library, notesStore: stack.library,
            textStore: stack.textStore, document: document)
        layoutWriterScreen(panel)
        // A real foreign-key failure, with no injected failure implementation.
        try stack.library.trash(document.id)
        try stack.library.emptyTrash()
        panel.composeField.text = "Keep this thought\nAnd this one"
        let saved = expectation(description: "save refused")
        panel.saveDraft { success in XCTAssertFalse(success); saved.fulfill() }
        wait(for: [saved], timeout: 3)
        XCTAssertEqual(panel.composeField.text, "Keep this thought\nAnd this one")
        XCTAssertTrue(panel.saveButton.isEnabled)
        XCTAssertTrue(panel.rows.isEmpty)
    }

    @MainActor
    func testDeletingANoteRemovesItFromTheStoreAndTheList() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")
        let note = WriterNote(documentIDs: [document.id], text: "Doomed")
        try stack.library.insert(note)
        try stack.library.attach(note.id, to: document.id, attachment: .manual)

        let panel = DocumentNotesPanelViewController(
            library: stack.library, notesStore: stack.library, textStore: stack.textStore, document: document)
        layoutWriterScreen(panel)
        XCTAssertTrue(panel.deleteNote(note.id))

        XCTAssertNil(try stack.library.note(note.id))
        XCTAssertFalse(panel.rows.contains { $0.id == note.id })
    }

    @MainActor
    func testAnAnchorThatNoLongerResolvesIsMarkedOrphaned() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        var document = try stack.library.createDocument(in: group.id, title: "Sheet")
        try stack.textStore.saveText("Original wording entirely.", for: &document)

        let anchor = TextAnchor(start: 0, end: 8, exact: "Original")
        let note = WriterNote(documentIDs: [document.id], text: "About the wording", anchor: anchor)
        try stack.library.insert(note)
        try stack.library.attach(note.id, to: document.id, attachment: .manual)

        // Rewrite the sheet so the anchored text is gone entirely.
        try stack.textStore.saveText("Completely different content now.", for: &document)

        let panel = DocumentNotesPanelViewController(
            library: stack.library, notesStore: stack.library, textStore: stack.textStore, document: document)
        layoutWriterScreen(panel)

        XCTAssertTrue(panel.orphanedNoteIDs.contains(note.id))
    }

    /// organiser #31: a note added via "@", voice, or an intent while the
    /// panel is open was invisible until the panel was reopened.
    @MainActor
    func testANoteAddedElsewhereWhileThePanelIsOpenAppearsWithoutReopening() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "G", icon: "folder", parent: nil)
        let document = try stack.library.createDocument(in: group.id, title: "Sheet")

        let panel = DocumentNotesPanelViewController(
            library: stack.library, notesStore: stack.library,
            textStore: stack.textStore, document: document)
        layoutWriterScreen(panel)
        XCTAssertTrue(panel.rows.isEmpty)

        let note = WriterNote(documentIDs: [document.id], text: "Added elsewhere")
        try stack.library.insert(note)
        try stack.library.attach(note.id, to: document.id, attachment: .manual)

        // `LibraryChangeBroadcaster` posts on the main queue after the write
        // commits, so the panel's observer callback lands one run-loop turn
        // later.
        pollUntil { panel.rows.contains { $0.id == note.id } }
        XCTAssertTrue(panel.rows.contains { $0.id == note.id })
    }
}
