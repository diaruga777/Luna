//
//  EditorRestorationTests.swift
//  LunaWriterTests
//

import UIKit
import XCTest
@testable import LunaWriterEditor
import LunaWriterModels
import LunaWriterStorage

/// The editor's half of "reopen on the same page": the caret goes back where
/// it was and the keyboard comes up only when it was up.
final class EditorRestorationTests: XCTestCase {

    @MainActor
    private func makeEditor(text: String) throws -> (EditorViewController, WriterStorageStack) {
        let stack = try makeWriterStack()
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Draft")
        try stack.textStore.saveText(text, for: &document)
        let session = try DocumentSession(
            document: document, textStore: stack.textStore, marksStore: stack.library,
            settings: stack.settings)
        let editor = EditorViewController(
            session: session,
            environment: EditorEnvironment(
                noteIndex: stack.noteIndex, noteStore: stack.library, marksStore: stack.library,
                settings: stack.settings))
        return (editor, stack)
    }

    @MainActor
    func testARestoredCaretAndKeyboardLand() throws {
        let (editor, _) = try makeEditor(text: "The quick brown fox.")
        editor.restoreEditingState(EditorEditingState(caretLocation: 10, isKeyboardVisible: true))
        let window = hostWriterScreen(editor)
        defer { editor.close(); window.isHidden = true }

        pollUntil { editor.textView.isFirstResponder }
        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 10, length: 0))
        XCTAssertTrue(editor.textView.isFirstResponder, "the keyboard was up, so it comes back up")
        XCTAssertEqual(
            editor.editingState,
            EditorEditingState(caretLocation: 10, isKeyboardVisible: true))
    }

    @MainActor
    func testARestoredSheetWhoseKeyboardWasDownOpensWithoutOne() throws {
        let (editor, _) = try makeEditor(text: "The quick brown fox.")
        editor.restoreEditingState(EditorEditingState(caretLocation: 4, isKeyboardVisible: false))
        let window = hostWriterScreen(editor)
        defer { editor.close(); window.isHidden = true }

        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 4, length: 0))
        XCTAssertFalse(editor.textView.isFirstResponder)
    }

    /// The app came back to the foreground with the sheet already on screen:
    /// the keyboard rises now, with no new appearance to wait for.
    @MainActor
    func testRestoringOnAnOnScreenEditorRaisesTheKeyboardAtOnce() throws {
        let (editor, _) = try makeEditor(text: "The quick brown fox.")
        let window = hostWriterScreen(editor)
        defer { editor.close(); window.isHidden = true }
        XCTAssertFalse(editor.textView.isFirstResponder)

        editor.restoreEditingState(EditorEditingState(caretLocation: 3, isKeyboardVisible: true))

        XCTAssertTrue(editor.textView.isFirstResponder)
        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 3, length: 0))
    }

    /// The file may have been edited elsewhere since the caret was recorded.
    @MainActor
    func testACaretPastTheEndOfTheTextIsClampedToIt() throws {
        let (editor, _) = try makeEditor(text: "Short.")
        editor.restoreEditingState(EditorEditingState(caretLocation: 900, isKeyboardVisible: false))
        let window = hostWriterScreen(editor)
        defer { editor.close(); window.isHidden = true }

        XCTAssertEqual(editor.textView.selectedRange, NSRange(location: 6, length: 0))
    }

    /// The rule that predates restoration: a sheet with nothing in it takes
    /// the keyboard, because there is nothing else to do there.
    @MainActor
    func testAnEmptySheetWithNoRecordedStateStillTakesTheKeyboard() throws {
        let (editor, _) = try makeEditor(text: "")
        let window = hostWriterScreen(editor)
        defer { editor.close(); window.isHidden = true }

        pollUntil { editor.textView.isFirstResponder }
        XCTAssertTrue(editor.textView.isFirstResponder)
    }

    @MainActor
    func testTheEditorReportsWhereTheCaretCameToRest() throws {
        let (editor, _) = try makeEditor(text: "The quick brown fox.")
        let recorder = RecordingEditorDelegate()
        editor.delegate = recorder
        let window = hostWriterScreen(editor)
        defer { editor.close(); window.isHidden = true }

        editor.textView.becomeFirstResponder()
        pollUntil { editor.textView.isFirstResponder }
        editor.textView.selectedRange = NSRange(location: 9, length: 0)
        editor.textViewDidBeginEditing(editor.textView)

        XCTAssertEqual(
            recorder.states.last, EditorEditingState(caretLocation: 9, isKeyboardVisible: true))

        editor.textView.resignFirstResponder()
        editor.textViewDidEndEditing(editor.textView)
        XCTAssertEqual(recorder.states.last?.isKeyboardVisible, false)
    }
}

@MainActor
private final class RecordingEditorDelegate: EditorViewControllerDelegate {
    var states: [EditorEditingState] = []
    func editorRequestsNotesPanel(_ editor: EditorViewController) {}
    func editorDidUpdateDocument(_ editor: EditorViewController, document: WriterDocument) {}
    func editorDidChangeEditingState(_ editor: EditorViewController, state: EditorEditingState) {
        states.append(state)
    }
}
