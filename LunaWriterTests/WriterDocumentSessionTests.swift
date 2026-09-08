//
//  WriterDocumentSessionTests.swift
//  LunaWriterTests
//

import XCTest
@testable import LunaWriterEditor
import LunaWriterModels
import LunaWriterStorage
import LunaWriterText

private final class SessionRecorder: DocumentSessionDelegate {
    var saves = 0
    var orphans: [Annotation] = []
    var externalChanges = 0

    func documentSessionDidSave(_ session: DocumentSession) { saves += 1 }
    func documentSession(_ session: DocumentSession, didReanchorWithOrphans orphans: [Annotation]) {
        self.orphans.append(contentsOf: orphans)
    }
    func documentSessionDidReceiveExternalChange(_ session: DocumentSession) { externalChanges += 1 }
}

final class WriterDocumentSessionTests: XCTestCase {

    private var stack: WriterStorageStack!
    private var document: WriterDocument!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stack = try makeWriterStack()
        document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Draft")
        var seeded = document!
        try stack.textStore.saveText("The first sentence. The second sentence.", for: &seeded)
        document = seeded
    }

    override func tearDown() {
        stack = nil
        super.tearDown()
    }

    private func makeSession(_ document: WriterDocument? = nil) throws -> DocumentSession {
        try DocumentSession(
            document: document ?? self.document,
            textStore: stack.textStore,
            marksStore: stack.library,
            settings: stack.settings,
            snapshots: stack.library)
    }

    private func type(_ text: String, into session: DocumentSession, at location: Int) {
        let edit = NSRange(location: location, length: 0)
        session.storage.replaceCharacters(in: edit, with: text)
    }

    /// `save()` writes off the keystroke's own thread now; a test that
    /// needs the write to have actually landed polls for it instead of
    /// assuming `session.save()` returning means the file changed.
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

    // MARK: - Loading

    func testTheSessionOpensOnTheTextOnDisk() throws {
        let session = try makeSession()
        XCTAssertEqual(session.text, "The first sentence. The second sentence.")
    }

    // MARK: - Autosave

    func testTypingDoesNotSaveUntilThePauseIsOver() throws {
        let session = try makeSession()
        let recorder = SessionRecorder()
        session.delegate = recorder

        type("Added. ", into: session, at: 0)
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertEqual(recorder.saves, 0)
        XCTAssertEqual(try stack.textStore.loadText(session.document), "The first sentence. The second sentence.")

        waitUntil { recorder.saves == 1 }
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(try stack.textStore.loadText(session.document), "Added. The first sentence. The second sentence.")
    }

    func testSavingWithNothingChangedWritesNothing() throws {
        let session = try makeSession()
        let recorder = SessionRecorder()
        session.delegate = recorder
        session.save()
        XCTAssertEqual(recorder.saves, 0)
    }

    func testGoingToTheBackgroundSaves() throws {
        let session = try makeSession()
        type("X", into: session, at: 0)
        session.applicationDidEnterBackground()
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertTrue(try stack.textStore.loadText(session.document).hasPrefix("X"))
    }

    func testSavingTakesTheNewTitleAndCounts() throws {
        let session = try makeSession()
        let recorder = SessionRecorder()
        session.delegate = recorder
        type("# Sea Notes\n\n", into: session, at: 0)
        session.save()
        waitUntil { recorder.saves == 1 }
        XCTAssertEqual(session.document.title, "Sea Notes")
        XCTAssertGreaterThan(session.document.wordCount, 0)
        XCTAssertGreaterThan(session.document.revision, document.revision)
    }

    /// The revision guard: a slower write must never clobber a newer one
    /// that already landed. saveNow() forces the second save to overtake
    /// the first (still in flight on the serial queue) and land first;
    /// the async save() issued for the SAME edit is now stale and must be
    /// a no-op once it completes.
    func testASlowerSaveNeverClobbersANewerOneThatAlreadyLanded() throws {
        let session = try makeSession()
        let recorder = SessionRecorder()
        session.delegate = recorder

        type("First. ", into: session, at: 0)
        session.save()
        type("Second. ", into: session, at: 0)
        // saveNow() waits out the queue, including the async write above,
        // so this is guaranteed to be the LAST write to actually run.
        XCTAssertTrue(session.saveNow())

        XCTAssertEqual(
            try stack.textStore.loadText(session.document),
            "Second. First. The first sentence. The second sentence.")
        // The async save's own answer, about the now-superseded revision,
        // still has to land on main — give it the chance, then confirm it
        // was a no-op rather than a second, stale documentSessionDidSave.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(recorder.saves, 1)
    }

    func testAnImmediateFlushFinishesTheSaveWhoseCompletionIsStillQueued() throws {
        let session = try makeSession()
        type("# New title\n", into: session, at: 0)
        session.save()
        XCTAssertTrue(session.hasUnsavedChanges, "A queued write is not saved yet")
        XCTAssertTrue(session.saveNow())
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(session.document.title, "New title")
        XCTAssertEqual(try stack.textStore.loadText(session.document), session.text)
        XCTAssertEqual(try stack.library.document(document.id)?.fileRelativePath, session.document.fileRelativePath)
    }

    func testAFailedQueuedSaveCanBeRetriedWithoutLosingTheDirtyBuffer() throws {
        let session = try makeSession()
        type("Keep this. ", into: session, at: 0)
        // Turn the temporary library directory into a file to produce a real
        // write failure, then restore the directory and retry the same edit.
        try FileManager.default.removeItem(at: stack.libraryRoot)
        try Data().write(to: stack.libraryRoot)
        session.save()
        XCTAssertFalse(session.saveNow())
        XCTAssertTrue(session.hasUnsavedChanges)
        try FileManager.default.removeItem(at: stack.libraryRoot)
        try FileManager.default.createDirectory(at: stack.libraryRoot, withIntermediateDirectories: true)
        XCTAssertTrue(session.saveNow())
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertFalse(session.hasUnsavedChanges, "A late failed completion must not undo a successful retry")
        XCTAssertEqual(try stack.textStore.loadText(session.document), session.text)
    }

    func testConsecutiveRenamingSavesLeaveOnlyTheLatestFile() throws {
        let session = try makeSession()
        session.replaceWholeText("# First title\nBody")
        session.save()
        session.replaceWholeText("# Second title\nBody")
        XCTAssertTrue(session.saveNow())
        let files = try FileManager.default.subpathsOfDirectory(atPath: stack.libraryRoot.path)
            .filter { $0.hasSuffix(".md") }
        XCTAssertEqual(files, [session.document.fileRelativePath])
        XCTAssertEqual(try stack.textStore.loadText(session.document), "# Second title\nBody")
    }

    func testAutosavePreservesMetadataChangedWhileTheEditorWasOpen() throws {
        let session = try makeSession()
        try stack.library.setFavorite(true, for: document.id)
        try stack.library.setKeywords(["ideas"], for: document.id)
        type("Fresh text. ", into: session, at: 0)
        XCTAssertTrue(session.saveNow())
        let stored = try XCTUnwrap(stack.library.document(document.id))
        XCTAssertTrue(stored.isFavorite)
        XCTAssertEqual(stored.keywords, ["ideas"])
    }

    func testMarkAsMineIsSavedWithoutAnotherKeystroke() throws {
        let session = try makeSession()
        session.recordInsertion(NSRange(location: 0, length: 3), source: .pasted)
        XCTAssertTrue(session.saveNow())
        session.markAsOwn(NSRange(location: 0, length: 3))
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertTrue(session.saveNow())
        XCTAssertFalse(try stack.library.marks(for: document.id).authorship.contains { $0.source == .pasted })
    }

    @MainActor
    func testTypingAndUndoPersistThroughTheRealTextView() throws {
        let session = try makeSession()
        let environment = EditorEnvironment(noteIndex: stack.noteIndex, noteStore: stack.library,
            marksStore: stack.library, settings: stack.settings)
        let editor = EditorViewController(session: session, environment: environment)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = editor
        window.isHidden = false
        defer { window.isHidden = true }
        editor.loadViewIfNeeded()
        editor.textView.becomeFirstResponder()
        editor.textView.selectedRange = NSRange(location: 0, length: 0)
        editor.textView.insertText("Typed. ")
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertTrue(session.saveNow())
        XCTAssertTrue(try stack.textStore.loadText(session.document).hasPrefix("Typed. "))
        editor.textView.undoManager?.undo()
        XCTAssertTrue(session.hasUnsavedChanges)
        XCTAssertTrue(session.saveNow())
        XCTAssertEqual(try stack.textStore.loadText(session.document), "The first sentence. The second sentence.")
    }

    // MARK: - Marks

    func testAuthorshipAndAnnotationsComeBackOnTheNextOpen() throws {
        let session = try makeSession()
        let recorder = SessionRecorder()
        session.delegate = recorder
        session.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Pasted words. ")
        session.recordInsertion(NSRange(location: 0, length: 14), source: .pasted)

        let quoted = NSRange(location: 14, length: 19)
        let anchor = TextAnchorResolver.make(range: quoted, in: session.storage.nsText)
        session.add(Annotation(documentID: document.id, kind: .cut, source: .manual, anchor: anchor))
        session.save()
        waitUntil { recorder.saves == 1 }

        let reopened = try makeSession(session.document)
        XCTAssertEqual(reopened.authorship.spans.first?.source, .pasted)
        XCTAssertEqual(reopened.authorship.spans.first?.range.nsRange, NSRange(location: 0, length: 14))
        XCTAssertEqual(reopened.annotations.count, 1)
        XCTAssertEqual(reopened.annotations.first?.kind, .cut)
        XCTAssertEqual(reopened.annotations.first?.range, quoted)
        XCTAssertTrue(reopened.orphanedAnnotations.isEmpty)
    }

    func testAnAnnotationWhoseWordsAreGoneIsListedAsAnOrphan() throws {
        let session = try makeSession()
        let recorder = SessionRecorder()
        session.delegate = recorder
        let quoted = NSRange(location: 0, length: 19)
        session.add(Annotation(
            documentID: document.id, kind: .keep, source: .voice,
            anchor: TextAnchorResolver.make(range: quoted, in: session.storage.nsText)))
        session.save()
        waitUntil { recorder.saves == 1 }

        // The file is rewritten while the sheet is closed, so the anchor has
        // nothing left to hold on to.
        var onDisk = session.document
        try stack.textStore.saveText("Nothing of the kind remains in this file.", for: &onDisk)

        let reopenRecorder = SessionRecorder()
        let reopened = try DocumentSession(
            document: onDisk, textStore: stack.textStore, marksStore: stack.library,
            settings: stack.settings, snapshots: stack.library)
        reopened.delegate = reopenRecorder
        XCTAssertEqual(reopened.annotations.count, 0)
        XCTAssertEqual(reopened.orphanedAnnotations.count, 1)
    }

    func testAMarkMovesWithTheTextTypedBeforeIt() throws {
        let session = try makeSession()
        let quoted = NSRange(location: 20, length: 20)
        session.add(Annotation(
            documentID: document.id, kind: .expand, source: .manual,
            anchor: TextAnchorResolver.make(range: quoted, in: session.storage.nsText)))
        type("Hello. ", into: session, at: 0)
        XCTAssertEqual(session.annotations.first?.range.location, 27)
    }

    /// An edit that swallows an annotation's whole range whole moves it to
    /// `orphanedAnnotations` — kept, not silently dropped — same as one
    /// orphaned on load.
    func testAnAnnotationErasedByAnEditBecomesAnOrphanInstantly() throws {
        let session = try makeSession()
        let quoted = NSRange(location: 0, length: 19)
        session.add(Annotation(
            documentID: document.id, kind: .cut, source: .manual,
            anchor: TextAnchorResolver.make(range: quoted, in: session.storage.nsText)))
        XCTAssertEqual(session.annotations.count, 1)

        let recorder = SessionRecorder()
        session.delegate = recorder
        let edit = NSRange(location: 0, length: 19)
        session.storage.replaceCharacters(in: edit, with: "")

        XCTAssertTrue(session.annotations.isEmpty)
        XCTAssertEqual(session.orphanedAnnotations.count, 1)
        XCTAssertEqual(session.orphanedAnnotations.first?.kind, .cut)
        XCTAssertEqual(recorder.orphans.count, 1)
    }

    // MARK: - Snapshots

    func testClosingAChangedSheetKeepsACopy() throws {
        let session = try makeSession()
        type("Changed. ", into: session, at: 0)
        session.close()
        let snapshots = try stack.library.snapshots(for: session.document.id)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(try XCTUnwrap(snapshots.first).text.hasPrefix("Changed. "))
    }

    func testClosingAnUntouchedSheetKeepsNothing() throws {
        let session = try makeSession()
        session.close()
        XCTAssertTrue(try stack.library.snapshots(for: session.document.id).isEmpty)
    }

    func testClosingSavesWhatWasStillPending() throws {
        let session = try makeSession()
        type("Kept. ", into: session, at: 0)
        session.close()
        XCTAssertTrue(try stack.textStore.loadText(session.document).hasPrefix("Kept. "))
    }

    func testRefreshingAnExternalRevisionUpdatesTheOpenBuffer() throws {
        let session = try makeSession()
        var external = session.document
        try stack.textStore.saveText("Rewritten elsewhere", for: &external)
        session.refreshDocument(external)
        waitUntil { session.text == "Rewritten elsewhere" }
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(session.document.revision, external.revision)
    }

    func testTypingDuringAnExternalReloadKeepsTheLocalEdit() throws {
        let session = try makeSession()
        var external = session.document
        try stack.textStore.saveText("Rewritten elsewhere", for: &external)
        session.refreshDocument(external)
        type("Local. ", into: session, at: 0)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(session.text, "Local. The first sentence. The second sentence.")
        XCTAssertTrue(session.hasUnsavedChanges)
        session.close()
    }

    // MARK: - External change

    func testAnExternalChangeReplacesTheTextAndPutsTheMarksBack() throws {
        let session = try makeSession()
        let recorder = SessionRecorder()
        session.delegate = recorder
        let quoted = NSRange(location: 4, length: 15)
        session.add(Annotation(
            documentID: document.id, kind: .needsWork, source: .manual,
            anchor: TextAnchorResolver.make(range: quoted, in: session.storage.nsText)))

        session.externalChangeArrived(text: "A new opening. The first sentence. The second sentence.")

        XCTAssertEqual(recorder.externalChanges, 1)
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(session.annotations.count, 1)
        XCTAssertEqual(
            session.storage.nsText.substring(with: try XCTUnwrap(session.annotations.first).range),
            "first sentence.")
    }

    /// Authorship spans are plain ranges with no anchor of their own; an
    /// external change resets them rather than leaving them pointing at
    /// whatever now sits at their old offsets.
    func testAnExternalChangeResetsAuthorship() throws {
        let session = try makeSession()
        session.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Pasted. ")
        session.recordInsertion(NSRange(location: 0, length: 8), source: .pasted)
        XCTAssertFalse(session.authorship.spans.isEmpty)

        session.externalChangeArrived(text: "Something else entirely, written elsewhere.")

        XCTAssertTrue(session.authorship.spans.isEmpty)
    }

    func testReplaceWholeTextRecordsASnapshotOfWhatWasThereAndMarksItDirty() throws {
        let session = try makeSession()
        let recorder = SessionRecorder()
        session.delegate = recorder

        session.replaceWholeText("A completely different sheet.")

        XCTAssertEqual(session.text, "A completely different sheet.")
        XCTAssertEqual(recorder.externalChanges, 1)
        XCTAssertTrue(session.hasUnsavedChanges)
        let snapshots = try stack.library.snapshots(for: session.document.id)
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.text, "The first sentence. The second sentence.")
    }
}
