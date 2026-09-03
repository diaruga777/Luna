//
//  ExternalChangeReconcilerTests.swift
//  LunaTests
//

import Foundation
import XCTest
@testable import LunaWriterStorage
import LunaWriterModels

final class ExternalChangeReconcilerTests: XCTestCase {

    // MARK: - Added

    func testAFileLunaHasNeverSeenBecomesASheetInTheGroupItsFolderNames() throws {
        let stack = try makeWriterStack()
        try writeWriterFile("# Found\n\nWritten in Files.", at: "Inbox/Found.md", in: stack)

        let outcome = try stack.reconciler.reconcile(scan(stack))

        XCTAssertEqual(outcome.added.count, 1)
        let document = try XCTUnwrap(try stack.library.document(try XCTUnwrap(outcome.added.first)))
        XCTAssertEqual(document.title, "Found")
        XCTAssertEqual(document.snippet, "Written in Files.")
        XCTAssertEqual(document.groupID, stack.library.inboxGroupID)
        XCTAssertEqual(document.fileRelativePath, "Inbox/Found.md")
        XCTAssertEqual(document.wordCount, 4)
    }

    func testAFolderNobodyMadeInLunaBecomesAGroup() throws {
        let stack = try makeWriterStack()
        try writeWriterFile("# Deep", at: "Travel/Japan/Deep.md", in: stack)

        let outcome = try stack.reconciler.reconcile(scan(stack))

        let document = try XCTUnwrap(try stack.library.document(try XCTUnwrap(outcome.added.first)))
        let groups = try stack.library.groups()
        let japan = try XCTUnwrap(groups.first { $0.name == "Japan" })
        let travel = try XCTUnwrap(groups.first { $0.name == "Travel" })
        XCTAssertEqual(document.groupID, japan.id)
        XCTAssertEqual(japan.parentID, travel.id)
        XCTAssertNil(travel.parentID)
    }

    func testAdoptingTheSameFileTwiceDoesNotMakeASecondSheet() throws {
        let stack = try makeWriterStack()
        try writeWriterFile("# Found", at: "Inbox/Found.md", in: stack)

        _ = try stack.reconciler.reconcile(scan(stack))
        let second = try stack.reconciler.reconcile(scan(stack))

        XCTAssertEqual(second.added.count, 0)
        XCTAssertEqual(
            try stack.library.documents(matching: FilterPredicate(), scope: nil).count, 1)
        XCTAssertEqual(second.changed.count, 0)
    }

    func testAnAdoptedSheetIsSearchable() throws {
        let stack = try makeWriterStack()
        try writeWriterFile("# Harbour\n\nThe lights at dusk.", at: "Inbox/Harbour.md", in: stack)

        let outcome = try stack.reconciler.reconcile(scan(stack))

        XCTAssertEqual(
            try stack.library.searchDocuments("dusk", limit: 5).map(\.documentID),
            outcome.added)
    }

    // MARK: - Changed

    func testAFileEditedElsewhereIsReloadedAndSnapshotted() throws {
        let stack = try makeWriterStack()
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: nil)
        try stack.textStore.saveText("# Draft\n\nFirst pass.", for: &document)

        try writeWriterFile(
            "# Draft\n\nSecond pass, longer now.", at: document.fileRelativePath, in: stack,
            modified: Date().addingTimeInterval(60))
        let outcome = try stack.reconciler.reconcile(scan(stack))

        XCTAssertEqual(outcome.changed, [document.id])
        let reloaded = try XCTUnwrap(try stack.library.document(document.id))
        XCTAssertEqual(reloaded.snippet, "Second pass, longer now.")
        XCTAssertEqual(reloaded.revision, document.revision + 1)
        XCTAssertEqual(
            try stack.library.snapshots(for: document.id).first?.text,
            "# Draft\n\nSecond pass, longer now.")
    }

    func testAFileOlderThanTheRowIsLeftAlone() throws {
        let stack = try makeWriterStack()
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: nil)
        try stack.textStore.saveText("# Draft\n\nFirst pass.", for: &document)

        let outcome = try stack.reconciler.reconcile(scan(stack))

        XCTAssertEqual(outcome.changed, [])
        XCTAssertEqual(try stack.library.document(document.id)?.revision, document.revision)
        XCTAssertEqual(try stack.library.snapshots(for: document.id).count, 0)
    }

    func testAMarkFollowsTheTextItWasMadeOn() throws {
        let stack = try makeWriterStack()
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: nil)
        let original = "# Draft\n\nThe quick brown fox jumps.\n"
        try stack.textStore.saveText(original, for: &document)
        let quoted = "brown fox"
        let start = (original as NSString).range(of: quoted).location
        try stack.library.replaceMarks(
            DocumentMarks(
                annotations: [Annotation(
                    documentID: document.id, kind: .keep, source: .voice,
                    anchor: TextAnchor(
                        start: start, end: start + quoted.utf16.count, exact: quoted,
                        prefix: "The quick ", suffix: " jumps."))],
                authorship: [AuthorshipSpan(
                    range: TextRange(start: 0, end: (original as NSString).length),
                    source: .pasted)]),
            for: document.id)

        let edited = "# Draft\n\nA paragraph that was not there before.\n\nThe quick brown fox jumps.\n"
        try writeWriterFile(
            edited, at: document.fileRelativePath, in: stack,
            modified: Date().addingTimeInterval(60))
        try stack.reconciler.reconcile(scan(stack))

        let marks = try stack.library.marks(for: document.id)
        XCTAssertEqual(marks.annotations.count, 1)
        XCTAssertEqual(
            marks.annotations.first?.anchor.start, (edited as NSString).range(of: quoted).location)
        XCTAssertEqual(marks.annotations.first?.kind, .keep)
        XCTAssertEqual(
            marks.authorship.first?.range.end, (original as NSString).length,
            "a span still inside the text keeps its range")
    }

    func testAMarkWhoseTextIsGoneIsDroppedRatherThanLeftPointingAtNothing() throws {
        let stack = try makeWriterStack()
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: nil)
        try stack.textStore.saveText("# Draft\n\nThe quick brown fox jumps.\n", for: &document)
        try stack.library.replaceMarks(
            DocumentMarks(annotations: [Annotation(
                documentID: document.id, kind: .cut,
                anchor: TextAnchor(start: 15, end: 24, exact: "brown fox"))]),
            for: document.id)

        try writeWriterFile(
            "# Draft\n\nNothing of the kind remains here.\n", at: document.fileRelativePath,
            in: stack, modified: Date().addingTimeInterval(60))
        try stack.reconciler.reconcile(scan(stack))

        XCTAssertEqual(try stack.library.marks(for: document.id).annotations.count, 0)
    }

    func testAnOpenSheetWithUnsavedEditsIsLeftForItsSession() throws {
        let stack = try makeWriterStack()
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: nil)
        try stack.textStore.saveText("# Draft\n\nFirst pass.", for: &document)
        let open = StubOpenDocuments()
        open.unsaved = [document.id]
        stack.reconciler.openDocuments = open

        try writeWriterFile(
            "# Draft\n\nSecond pass.", at: document.fileRelativePath, in: stack,
            modified: Date().addingTimeInterval(60))
        let outcome = try stack.reconciler.reconcile(scan(stack))

        XCTAssertEqual(outcome.deferred, [document.id])
        XCTAssertEqual(outcome.changed, [])
        XCTAssertEqual(try stack.library.document(document.id)?.snippet, "First pass.")

        open.unsaved = []
        let later = try stack.reconciler.reconcile(scan(stack))
        XCTAssertEqual(later.changed, [document.id])
        XCTAssertEqual(try stack.library.document(document.id)?.snippet, "Second pass.")
    }

    func testAnAuthorshipSpanIsClampedWhenTheTextShrinks() throws {
        let stack = try makeWriterStack()
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: nil)
        let original = "# Draft\n\nThe quick brown fox jumps over the lazy dog.\n"
        try stack.textStore.saveText(original, for: &document)
        try stack.library.replaceMarks(
            DocumentMarks(authorship: [
                AuthorshipSpan(
                    range: TextRange(start: 0, end: (original as NSString).length),
                    source: .ai(model: "test")),
                AuthorshipSpan(
                    range: TextRange(
                        start: (original as NSString).length - 4,
                        end: (original as NSString).length),
                    source: .pasted),
            ]),
            for: document.id)

        let shortened = "# Draft\n"
        try writeWriterFile(
            shortened, at: document.fileRelativePath, in: stack,
            modified: Date().addingTimeInterval(60))
        try stack.reconciler.reconcile(scan(stack))

        let marks = try stack.library.marks(for: document.id)
        XCTAssertEqual(marks.authorship.count, 1)
        XCTAssertEqual(marks.authorship.first?.range.end, (shortened as NSString).length)
        XCTAssertEqual(marks.authorship.first?.source, .ai(model: "test"))
    }

    // MARK: - Deleted

    func testAFileThatIsGoneTrashesItsSheetRatherThanErasingIt() throws {
        let stack = try makeWriterStack()
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: nil)
        try stack.textStore.saveText("# Draft\n\nFirst pass.", for: &document)
        try stack.library.recordSnapshot("# Draft\n\nFirst pass.", for: document.id)
        try FileManager.default.removeItem(
            at: stack.libraryRoot.appendingPathComponent(document.fileRelativePath))

        let outcome = try stack.reconciler.reconcile(scan(stack))

        XCTAssertEqual(outcome.trashed, [document.id])
        XCTAssertNotNil(try stack.library.document(document.id))
        XCTAssertNotNil(try stack.library.document(document.id)?.trashedAt)
        XCTAssertEqual(
            try stack.library.snapshots(for: document.id).first?.text, "# Draft\n\nFirst pass.")
    }

    func testASheetWithNoFileYetIsNotTrashedByAScan() throws {
        let stack = try makeWriterStack()
        let document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "New")

        let outcome = try stack.reconciler.reconcile(scan(stack))

        XCTAssertEqual(outcome.trashed, [])
        XCTAssertNil(try stack.library.document(document.id)?.trashedAt)
    }

    // MARK: - Trash and delete leave no orphaned files

    func testTrashingASheetThenScanningDoesNotResurrectIt() throws {
        let stack = try makeWriterStack()
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: nil)
        try stack.textStore.saveText("# Draft\n\nFirst pass.", for: &document)

        try stack.library.trash(document.id)
        let outcome = try stack.reconciler.reconcile(scan(stack))

        XCTAssertEqual(outcome.added, [])
        XCTAssertEqual(try stack.library.documents(matching: FilterPredicate(), scope: nil).count, 0)
        XCTAssertNotNil(try stack.library.document(document.id)?.trashedAt)
    }

    func testEmptyingTheTrashThenScanningDoesNotResurrectAnything() throws {
        let stack = try makeWriterStack()
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: nil)
        try stack.textStore.saveText("# Draft\n\nFirst pass.", for: &document)
        try stack.library.trash(document.id)

        try stack.library.emptyTrash()
        let outcome = try stack.reconciler.reconcile(scan(stack))

        XCTAssertEqual(outcome.added, [])
        XCTAssertNil(try stack.library.document(document.id))
    }

    func testDeletingAGroupThenScanningDoesNotResurrectItsSheets() throws {
        let stack = try makeWriterStack()
        let group = try stack.library.createGroup(name: "Travel", icon: "folder", parent: nil)
        var document = try stack.library.createDocument(in: group.id, title: nil)
        try stack.textStore.saveText("# Deep\n\nSome text.", for: &document)

        try stack.library.delete(group.id)
        let outcome = try stack.reconciler.reconcile(scan(stack))

        XCTAssertEqual(outcome.added, [])
        XCTAssertNil(try stack.library.groups().first { $0.name == "Travel" })
        XCTAssertNotNil(try stack.library.document(document.id)?.trashedAt)
    }

    // MARK: - Identity survives a disappearance or a rename

    func testAFileThatDisappearsThenReturnsIsRestoredRatherThanReadopted() throws {
        let stack = try makeWriterStack()
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: nil)
        try stack.textStore.saveText("# Draft\n\nFirst pass.", for: &document)
        let path = document.fileRelativePath

        try FileManager.default.removeItem(at: stack.libraryRoot.appendingPathComponent(path))
        let gone = try stack.reconciler.reconcile(scan(stack))
        XCTAssertEqual(gone.trashed, [document.id])

        try writeWriterFile(
            "# Draft\n\nFirst pass.", at: path, in: stack, modified: Date().addingTimeInterval(120))
        let outcome = try stack.reconciler.reconcile(scan(stack))

        XCTAssertEqual(outcome.added, [])
        XCTAssertEqual(outcome.changed, [document.id])
        XCTAssertNil(try stack.library.document(document.id)?.trashedAt)
        XCTAssertEqual(
            try stack.library.documents(matching: FilterPredicate(), scope: nil).count, 1)
    }

    func testRenamingAGroupFolderExternallyKeepsTheSheetsIdentityAndMarks() throws {
        let stack = try makeWriterStack()
        let original = "# Deep\n\nWritten while it was still Japan.\n"
        try writeWriterFile(original, at: "Travel/Japan/Deep.md", in: stack)
        let first = try stack.reconciler.reconcile(scan(stack))
        let documentID = try XCTUnwrap(first.added.first)
        let quoted = "still Japan"
        let start = (original as NSString).range(of: quoted).location
        try stack.library.replaceMarks(
            DocumentMarks(annotations: [Annotation(
                documentID: documentID, kind: .keep, source: .voice,
                anchor: TextAnchor(
                    start: start, end: start + quoted.utf16.count, exact: quoted,
                    prefix: "was ", suffix: ".\n"))]),
            for: documentID)

        try FileManager.default.removeItem(
            at: stack.libraryRoot.appendingPathComponent("Travel/Japan/Deep.md"))
        try writeWriterFile(
            original, at: "Trips/Japan/Deep.md", in: stack, modified: Date().addingTimeInterval(120))

        let outcome = try stack.reconciler.reconcile(scan(stack))

        XCTAssertEqual(outcome.added, [])
        XCTAssertEqual(outcome.trashed, [])
        XCTAssertEqual(outcome.changed, [documentID])
        let document = try XCTUnwrap(try stack.library.document(documentID))
        XCTAssertEqual(document.fileRelativePath, "Trips/Japan/Deep.md")
        XCTAssertNil(document.trashedAt)
        let groups = try stack.library.groups()
        let trips = try XCTUnwrap(groups.first { $0.name == "Trips" })
        let japanUnderTrips = groups.first { $0.name == "Japan" && $0.parentID == trips.id }
        XCTAssertEqual(document.groupID, japanUnderTrips?.id)
        XCTAssertEqual(try stack.library.marks(for: documentID).annotations.count, 1)
    }

    func testANFDPathOnDiskMatchesTheNFCPathTheRowStores() throws {
        let stack = try makeWriterStack()
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: nil)
        try stack.textStore.saveText("# Café\n\nFirst pass.", for: &document)
        XCTAssertEqual(document.fileRelativePath, "Inbox/Café.md")

        // A byte-for-byte different name on disk (decomposed, where the row
        // stores the composed form) — as APFS, which does not normalise
        // filenames, would actually hand back a name written elsewhere.
        try FileManager.default.removeItem(
            at: stack.libraryRoot.appendingPathComponent(document.fileRelativePath))
        let decomposedPath = document.fileRelativePath.decomposedStringWithCanonicalMapping
        try writeWriterFile(
            "# Café\n\nSecond pass, longer now.", at: decomposedPath, in: stack,
            modified: Date().addingTimeInterval(120))

        let outcome = try stack.reconciler.reconcile(scan(stack))

        XCTAssertEqual(outcome.added, [])
        XCTAssertEqual(outcome.changed, [document.id])
        XCTAssertEqual(
            try stack.library.document(document.id)?.snippet, "Second pass, longer now.")
    }

    private func scan(_ stack: WriterStorageStack) -> [ExternalFileSnapshot] {
        LibraryFolderWatcher.scan(stack.libraryRoot)
    }
}
