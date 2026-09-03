//
//  WriterDocumentSessionTests.swift
//  LunaTests
//

import XCTest
@testable import LunaWriterEditor
import LunaWriterModels
import LunaWriterStorage
import LunaWriterText

/// Holds the autosave deadline until the test says the pause is over.
private final class ManualAutosaveScheduler: AutosaveScheduling {
    private(set) var scheduleCount = 0
    private(set) var lastDelay: TimeInterval?
    private(set) var cancelCount = 0
    private weak var target: AutosaveScheduled?

    func schedule(after delay: TimeInterval, for target: AutosaveScheduled) {
        scheduleCount += 1
        lastDelay = delay
        self.target = target
    }

    func cancel() {
        cancelCount += 1
    }

    /// The pause after the last keystroke elapsed.
    func fire() {
        target?.autosaveDeadlineReached()
    }
}

private final class SessionRecorder: DocumentSessionDelegate {
    var saves = 0
    var orphans: [Annotation] = []
    var externalChanges = 0

    func documentSessionDidSave(_ session: DocumentSession) { saves += 1 }
    func documentSession(_ session: DocumentSession, didReanchorWithOrphans orphans: [Annotation]) {
        self.orphans = orphans
    }
    func documentSessionDidReceiveExternalChange(_ session: DocumentSession) { externalChanges += 1 }
}

final class WriterDocumentSessionTests: XCTestCase {

    private var stack: WriterStorageStack!
    private var document: WriterDocument!
    private var scheduler: ManualAutosaveScheduler!

    override func setUpWithError() throws {
        try super.setUpWithError()
        stack = try makeWriterStack()
        document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Draft")
        var seeded = document!
        try stack.textStore.saveText("The first sentence. The second sentence.", for: &seeded)
        document = seeded
        scheduler = ManualAutosaveScheduler()
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
            snapshots: stack.library,
            scheduler: scheduler)
    }

    private func type(_ text: String, into session: DocumentSession, at location: Int) {
        let edit = NSRange(location: location, length: 0)
        session.storage.replaceCharacters(in: edit, with: text)
        session.textDidChange(
            edit: edit, replacementLength: (text as NSString).length, typedBy: .author)
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

        scheduler.fire()
        XCTAssertFalse(session.hasUnsavedChanges)
        XCTAssertEqual(recorder.saves, 1)
        XCTAssertEqual(try stack.textStore.loadText(session.document), "Added. The first sentence. The second sentence.")
    }

    func testEveryKeystrokePushesTheDeadlineBack() throws {
        let session = try makeSession()
        type("a", into: session, at: 0)
        type("b", into: session, at: 1)
        type("c", into: session, at: 2)
        XCTAssertEqual(scheduler.scheduleCount, 3)
        XCTAssertEqual(scheduler.lastDelay, DocumentSession.autosaveDelay)
    }

    func testSavingWithNothingChangedWritesNothing() throws {
        let session = try makeSession()
        let recorder = SessionRecorder()
        session.delegate = recorder
        try session.save()
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
        type("# Sea Notes\n\n", into: session, at: 0)
        scheduler.fire()
        XCTAssertEqual(session.document.title, "Sea Notes")
        XCTAssertGreaterThan(session.document.wordCount, 0)
        XCTAssertGreaterThan(session.document.revision, document.revision)
    }

    // MARK: - Marks

    func testAuthorshipAndAnnotationsComeBackOnTheNextOpen() throws {
        let session = try makeSession()
        session.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Pasted words. ")
        session.recordInsertion(NSRange(location: 0, length: 14), source: .pasted)

        let quoted = NSRange(location: 14, length: 19)
        let anchor = TextAnchorResolver.make(range: quoted, in: session.storage.nsText)
        session.add(Annotation(documentID: document.id, kind: .cut, source: .manual, anchor: anchor))
        scheduler.fire()

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
        let quoted = NSRange(location: 0, length: 19)
        session.add(Annotation(
            documentID: document.id, kind: .keep, source: .voice,
            anchor: TextAnchorResolver.make(range: quoted, in: session.storage.nsText)))
        scheduler.fire()

        // The file is rewritten while the sheet is closed, so the anchor has
        // nothing left to hold on to.
        var onDisk = session.document
        try stack.textStore.saveText("Nothing of the kind remains in this file.", for: &onDisk)

        let recorder = SessionRecorder()
        let reopened = try DocumentSession(
            document: onDisk, textStore: stack.textStore, marksStore: stack.library,
            settings: stack.settings, snapshots: stack.library, scheduler: scheduler)
        reopened.delegate = recorder
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
}
