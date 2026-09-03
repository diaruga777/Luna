//
//  WriterLibraryUITestSupport.swift
//  LunaTests
//

import UIKit
import XCTest
@testable import LunaWriterLibraryUI
import LunaWriterModels
import LunaWriterStorage

/// A `DocumentEditing` screen a test controls directly: no real text layout,
/// just the seam `EditorContainerViewController` talks to.
final class FakeDocumentEditor: UIViewController, DocumentEditing {
    weak var editingDelegate: DocumentEditingDelegate?
    private(set) var document: WriterDocument
    private(set) var focusedAnchors: [TextAnchor] = []
    private(set) var flushCount = 0

    init(document: WriterDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func focus(on anchor: TextAnchor) { focusedAnchors.append(anchor) }
    func flushPendingSave() { flushCount += 1 }

    /// Simulates the real editor reporting a save back to its container.
    func simulateUpdate(_ document: WriterDocument) {
        self.document = document
        editingDelegate?.editor(self, didUpdate: document)
    }

    func simulateNotesPanelRequest() {
        editingDelegate?.editorRequestsNotesPanel(self)
    }
}

/// Builds a `FakeDocumentEditor` per sheet and remembers each one.
final class FakeDocumentEditorMaker: DocumentEditorMaking {
    private(set) var madeEditors: [FakeDocumentEditor] = []

    func makeEditor(for document: WriterDocument) -> UIViewController & DocumentEditing {
        let editor = FakeDocumentEditor(document: document)
        madeEditors.append(editor)
        return editor
    }
}

/// A scripted relevance witness, so a notes-panel test can assert on the
/// ordering the score map produces without a real embedding model.
final class ScriptedNoteRelevance: NoteRelevanceProviding {
    var scores: [DocumentID: [NoteID: Double]] = [:]
    func relevanceScores(for document: DocumentID) -> [NoteID: Double] { scores[document] ?? [:] }
}

/// A scripted read-along settings witness for the Settings screen tests.
final class ScriptedReadAlongSettings: ReadAlongSettingsHandling {
    var gazeAvailable = true
    var voiceAvailable = true
    var lastCalibrationGrade: String?
    private(set) var calibrationPresentedFrom: UIViewController?

    func presentCalibration(from presenter: UIViewController) {
        calibrationPresentedFrom = presenter
    }
}

extension XCTestCase {

    /// A `LibraryEnvironment` wired to a temp `WriterStorageStack`, with a
    /// fake editor maker the caller can inspect afterward.
    func makeLibraryEnvironment(
        stack: WriterStorageStack, editorMaker: FakeDocumentEditorMaker = FakeDocumentEditorMaker(),
        noteRelevance: NoteRelevanceProviding? = nil,
        readAlongSettings: ReadAlongSettingsHandling? = nil
    ) -> LibraryEnvironment {
        LibraryEnvironment(
            library: stack.library, notes: stack.library, marks: stack.library,
            textStore: stack.textStore, snapshots: stack.library, noteIndex: stack.noteIndex,
            settings: stack.settings, editorMaker: editorMaker, readAlongChrome: nil,
            readAlongSettings: readAlongSettings, noteRelevance: noteRelevance,
            libraryRootPath: stack.libraryRoot.path)
    }

    /// Loads `viewController`'s view and gives it a phone-sized, window-less
    /// frame so Auto Layout has something to resolve against.
    @MainActor
    func layoutWriterScreen(_ viewController: UIViewController, width: CGFloat = 390, height: CGFloat = 844) {
        viewController.loadViewIfNeeded()
        viewController.view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        viewController.view.layoutIfNeeded()
    }

    /// Pumps the run loop until `condition` is true or `timeout` elapses —
    /// for state a diffable data source applies on a later run-loop turn.
    @MainActor
    func pollUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
