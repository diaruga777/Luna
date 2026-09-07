//
//  EditorChromeToggleTests.swift
//  LunaTests
//

import UIKit
import XCTest
@testable import LunaWriterEditor
import LunaWriterModels
import LunaWriterStorage

/// The editor's half of the chrome-toggle double tap: `isBlankSpace(at:)`
/// decides whether a tap should flip the chrome or fall through to the
/// system's own word-selection gesture.
final class EditorChromeToggleTests: XCTestCase {

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
    func testATapOnTheFirstLineOfTextIsNotBlankSpace() throws {
        let (editor, _) = try makeEditor(text: "Hello world, this is the first line of the document.")
        let window = hostWriterScreen(editor)
        defer { editor.close(); window.isHidden = true }

        let position = try XCTUnwrap(editor.textView.position(from: editor.textView.beginningOfDocument, offset: 3))
        let caretRect = editor.textView.caretRect(for: position)
        let point = CGPoint(x: caretRect.midX, y: caretRect.midY)

        XCTAssertFalse(editor.isBlankSpace(at: point))
    }

    @MainActor
    func testATapBelowTheLastLineIsBlankSpace() throws {
        let (editor, _) = try makeEditor(text: "Hello world.")
        let window = hostWriterScreen(editor)
        defer { editor.close(); window.isHidden = true }

        let point = CGPoint(x: editor.textView.bounds.midX, y: editor.textView.bounds.maxY - 5)

        XCTAssertTrue(editor.isBlankSpace(at: point))
    }
}
