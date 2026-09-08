//
//  WriterLibraryUITestSupport.swift
//  LunaWriterTests
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
    private(set) var replacedTexts: [String] = []
    /// The state a restore handed in, and what `editingState` answers with.
    var editingState = EditorEditingState()
    private(set) var restoredStates: [EditorEditingState] = []

    init(document: WriterDocument) {
        self.document = document
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func focus(on anchor: TextAnchor) { focusedAnchors.append(anchor) }
    func flushPendingSave() { flushCount += 1 }
    func replaceText(_ text: String) { replacedTexts.append(text) }

    func restoreEditingState(_ state: EditorEditingState) {
        restoredStates.append(state)
        editingState = state
    }

    /// Simulates the real editor reporting the caret's resting position.
    func simulateEditingState(_ state: EditorEditingState) {
        editingState = state
        editingDelegate?.editor(self, didChangeEditingState: state)
    }

    /// Simulates the real editor reporting a save back to its container.
    func simulateUpdate(_ document: WriterDocument) {
        self.document = document
        editingDelegate?.editor(self, didUpdate: document)
    }

    func simulateNotesPanelRequest() {
        editingDelegate?.editorRequestsNotesPanel(self)
    }

    /// Simulates the real editor's chrome cue: typing began/ended, or the
    /// page reached its top.
    func simulateChromeHiddenRequest(_ hidden: Bool) {
        editingDelegate?.editor(self, wantsChromeHidden: hidden)
    }

    /// Simulates a double tap on blank space.
    func simulateChromeToggleRequest() {
        editingDelegate?.editorDidRequestChromeToggle(self)
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
        readAlongSettings: ReadAlongSettingsHandling? = nil
    ) -> LibraryEnvironment {
        LibraryEnvironment(
            library: stack.library, notes: stack.library, marks: stack.library,
            textStore: stack.textStore, snapshots: stack.library, noteIndex: stack.noteIndex,
            settings: stack.settings, sessionState: stack.sessionState,
            editorMaker: editorMaker, readAlongChrome: nil,
            readAlongSettings: readAlongSettings,
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

    /// Hosts `viewController` in a REAL (offscreen) window rather than the
    /// window-less frame `layoutWriterScreen` uses — a window-less view
    /// controller can queue a `present(_:animated:)` that never resolves
    /// `presentedViewController`, so a test asserting on a presented alert
    /// needs this instead. Keep the returned window alive for the rest of
    /// the test; a deallocated window tears the presentation down early.
    @discardableResult
    @MainActor
    func hostWriterScreen(
        _ viewController: UIViewController, width: CGFloat = 390, height: CGFloat = 844
    ) -> UIWindow {
        // Attached to the host's scene when there is one: a window with no
        // scene is never drawn, so its navigation transitions never finish
        // and UIKit drops every stack change made after the first.
        let window: UIWindow
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        } else {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: height))
        }
        window.rootViewController = viewController
        window.makeKeyAndVisible()
        viewController.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return window
    }

    @discardableResult
    @MainActor
    func hostWriterScreenInWindow(
        _ viewController: UIViewController, width: CGFloat = 390, height: CGFloat = 844
    ) -> UIWindow {
        hostWriterScreen(viewController, width: width, height: height)
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
