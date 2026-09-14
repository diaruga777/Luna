//
//  EditorNewChapterTests.swift
//  LunaWriterTests
//

import UIKit
import XCTest
@testable import LunaWriterEditor
import LunaWriterModels
import LunaWriterStorage

private final class ChapterRecorder: EditorViewControllerDelegate {
    var opened: [WriterDocument] = []
    func editorRequestsNotesPanel(_ editor: EditorViewController) {}
    func editorDidUpdateDocument(_ editor: EditorViewController, document: WriterDocument) {}
    func editor(_ editor: EditorViewController, didStartChapter chapter: WriterDocument) { opened.append(chapter) }
}

/// The editor's half of "new chapter": the text after the caret leaves this
/// sheet, is saved out, and comes back as the sheet the delegate is asked to open.
final class EditorNewChapterTests: XCTestCase {

    @MainActor
    func testTheTextAfterTheCaretBecomesTheNextChapterAndTheDelegateOpensIt() throws {
        let stack = try makeWriterStack()
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: nil)
        try stack.textStore.saveText("# Voyage\n\nOne.\n\nTwo.", for: &document)
        let session = try DocumentSession(
            document: document, textStore: stack.textStore, marksStore: stack.library, settings: stack.settings)
        let editor = EditorViewController(
            session: session,
            environment: EditorEnvironment(
                noteIndex: stack.noteIndex, noteStore: stack.library, marksStore: stack.library,
                settings: stack.settings,
                chapters: ChapterOrganizer(library: stack.library, textStore: stack.textStore)))
        let recorder = ChapterRecorder()
        editor.delegate = recorder
        let window = hostWriterScreen(editor)
        defer { editor.close(); window.isHidden = true }

        editor.textView.selectedRange = NSRange(location: 14, length: 0)
        editor.commandPaletteDidRequestNewChapter(CommandPaletteController(
            noteIndex: stack.noteIndex, noteStore: stack.library, documentID: document.id))

        XCTAssertEqual(session.text, "# Voyage\n\nOne.")
        let chapter = try XCTUnwrap(recorder.opened.first)
        XCTAssertEqual(try stack.textStore.loadText(chapter), "# Chapter 2\n\nTwo.")
        let reread = try XCTUnwrap(stack.library.document(document.id))
        XCTAssertEqual(try stack.textStore.loadText(reread), "# Voyage\n\nOne.", "the cut was saved before the split")
        XCTAssertEqual(reread.groupID, chapter.groupID)
    }
}
