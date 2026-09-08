import UIKit
import XCTest
@testable import LunaWriterEditor
import LunaWriterModels
import LunaWriterStorage

private final class DeferredWritingAssistant: AIWritingAssisting {
    let modelIdentifier = "test"
    let isAvailable = true
    var pending: CheckedContinuation<String, Never>?

    func continueWriting(context: String) async throws -> String {
        await withCheckedContinuation { pending = $0 }
    }
    func rewrite(_ text: String, instruction: String?) async throws -> String {
        await withCheckedContinuation { pending = $0 }
    }
    func answer(_ text: String) {
        pending?.resume(returning: text)
        pending = nil
    }
}

final class WriterAIEditingTests: XCTestCase {
    @MainActor
    private func makeEditor(assistant: DeferredWritingAssistant) throws -> (EditorViewController, UIWindow) {
        let stack = try makeWriterStack()
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Draft")
        try stack.textStore.saveText("The quick fox.", for: &document)
        let session = try DocumentSession(document: document, textStore: stack.textStore,
            marksStore: stack.library, settings: stack.settings)
        let editor = EditorViewController(session: session, environment: EditorEnvironment(
            noteIndex: stack.noteIndex, noteStore: stack.library, marksStore: stack.library,
            settings: stack.settings, aiAssistant: assistant))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = editor
        window.isHidden = false
        editor.loadViewIfNeeded()
        editor.textView.becomeFirstResponder()
        return (editor, window)
    }

    @MainActor
    func testRewriteIsOneUndoableEditWithAIAuthorship() throws {
        let assistant = DeferredWritingAssistant()
        let (editor, window) = try makeEditor(assistant: assistant)
        defer { editor.close(); window.isHidden = true }
        editor.textView.selectedRange = NSRange(location: 4, length: 5)
        editor.rewriteSelection()
        pollUntil { assistant.pending != nil }
        assistant.answer("red")
        pollUntil { editor.session.text == "The red fox." }
        XCTAssertTrue(editor.session.authorship.spans.contains {
            $0.source == .ai(model: "test") && $0.range.nsRange == NSRange(location: 4, length: 3)
        })
        editor.textView.undoManager?.undo()
        XCTAssertEqual(editor.session.text, "The quick fox.")
    }

    @MainActor
    func testTypingWhileGenerationRunsProtectsTheNewText() throws {
        let assistant = DeferredWritingAssistant()
        let (editor, window) = try makeEditor(assistant: assistant)
        defer { editor.close(); window.isHidden = true }
        editor.textView.selectedRange = NSRange(location: 4, length: 5)
        editor.rewriteSelection()
        pollUntil { assistant.pending != nil }
        editor.textView.insertText("my own")
        assistant.answer("must not replace my typing")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(editor.session.text, "The my own fox.")
        XCTAssertFalse(editor.session.authorship.spans.contains { $0.source == .ai(model: "test") })
    }
}
