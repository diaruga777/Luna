//
//  WriterDatabaseTests.swift
//  LunaTests
//

import Foundation
import XCTest
@testable import LunaWriterStorage

final class WriterDatabaseTests: XCTestCase {

    // MARK: - Migrations

    func testReopeningAMigratedFileKeepsItsRowsAndVersion() throws {
        let root = try makeWriterTemporaryDirectory()
        let url = root.appendingPathComponent("writer.sqlite")
        let groupName = "Essays"
        do {
            let database = try WriterDatabase(fileURL: url)
            let library = try SQLiteWriterLibrary(database: database)
            _ = try library.createGroup(name: groupName, icon: "folder", parent: nil)
            XCTAssertEqual(database.userVersion, WriterDatabase.schemaVersion)
        }
        let reopened = try WriterDatabase(fileURL: url)
        let library = try SQLiteWriterLibrary(database: reopened)
        XCTAssertEqual(reopened.userVersion, WriterDatabase.schemaVersion)
        XCTAssertEqual(try library.groups().filter { $0.name == groupName }.count, 1)
    }

    func testMigrationRunsAgainWithoutLosingRowsWhenTheVersionPragmaIsLost() throws {
        let root = try makeWriterTemporaryDirectory()
        let url = root.appendingPathComponent("writer.sqlite")
        let first = try WriterDatabase(fileURL: url)
        let library = try SQLiteWriterLibrary(database: first)
        let document = try library.createDocument(in: library.inboxGroupID, title: "Kept")
        try first.perform { try $0.setUserVersion(0) }

        let reopened = try WriterDatabase(fileURL: url)
        let reopenedLibrary = try SQLiteWriterLibrary(database: reopened)
        XCTAssertEqual(reopened.userVersion, WriterDatabase.schemaVersion)
        XCTAssertEqual(try reopenedLibrary.document(document.id)?.title, "Kept")
    }

    func testSystemGroupsExistOnceHoweverOftenTheLibraryIsOpened() throws {
        let root = try makeWriterTemporaryDirectory()
        let url = root.appendingPathComponent("writer.sqlite")
        let database = try WriterDatabase(fileURL: url)
        _ = try SQLiteWriterLibrary(database: database)
        let library = try SQLiteWriterLibrary(database: database)
        let groups = try library.groups()
        XCTAssertEqual(groups.filter { $0.kind == .inbox }.count, 1)
        XCTAssertEqual(groups.filter { $0.kind == .trash }.count, 1)
        XCTAssertEqual(groups.first { $0.kind == .inbox }?.id, library.inboxGroupID)
    }

    // MARK: - Unknown enum values

    func testUnknownEnumRawValuesReadAsTheSafeDefault() throws {
        let stack = try makeWriterStack()
        let library = stack.library
        let group = try library.createGroup(name: "Odd", icon: "folder", parent: nil)
        let document = try library.createDocument(in: group.id, title: "Odd sheet")
        let note = WriterNote(text: "note text", source: .typed)
        try library.insert(note)
        try library.replaceMarks(
            DocumentMarks(
                annotations: [Annotation(
                    documentID: document.id, kind: .cut, source: .voice,
                    anchor: TextAnchor(start: 0, end: 4, exact: "note"))],
                authorship: [AuthorshipSpan(range: TextRange(start: 0, end: 4), source: .pasted)]),
            for: document.id)

        try stack.database.transaction { db in
            try db.execute("UPDATE groups SET kind = 'from-a-newer-build'")
            try db.execute("UPDATE notes SET source = 'from-a-newer-build'")
            try db.execute("UPDATE annotations SET kind = 'shrug', source = 'shrug'")
            try db.execute("UPDATE authorship_spans SET source = 'shrug'")
            try db.execute("UPDATE documents SET goal_unit = 'shrug', goal_target = 5, goal_mode = 'shrug'")
        }

        XCTAssertEqual(try library.groups().first { $0.id == group.id }?.kind, .user)
        XCTAssertEqual(try library.note(note.id)?.source, .typed)
        let marks = try library.marks(for: document.id)
        XCTAssertEqual(marks.annotations.first?.kind, .comment)
        XCTAssertEqual(marks.annotations.first?.source, .manual)
        XCTAssertEqual(marks.authorship.first?.source, .author)
        XCTAssertEqual(try library.document(document.id)?.goal?.unit, .words)
        XCTAssertEqual(try library.document(document.id)?.goal?.mode, .atLeast)
    }

    // MARK: - Cascades

    func testEmptyingTheTrashRemovesEverythingHangingOffTheSheet() throws {
        let stack = try makeWriterStack()
        let library = stack.library
        var document = try library.createDocument(in: library.inboxGroupID, title: "Doomed")
        document.keywords = ["Draft", "draft", "essay"]
        try library.update(document)

        let note = WriterNote(documentIDs: [document.id], text: "a note on it", source: .typed)
        try library.insert(note)
        try library.replaceMarks(
            DocumentMarks(
                annotations: [Annotation(
                    documentID: document.id, kind: .keep,
                    anchor: TextAnchor(start: 0, end: 1, exact: "a"))],
                authorship: [AuthorshipSpan(range: TextRange(start: 0, end: 3), source: .pasted)]),
            for: document.id)
        try library.recordSnapshot("earlier text", for: document.id)
        XCTAssertEqual(try library.document(document.id)?.keywords, ["draft", "essay"])

        try library.trash(document.id)
        try library.emptyTrash()

        XCTAssertNil(try library.document(document.id))
        XCTAssertEqual(try library.marks(for: document.id), .empty)
        XCTAssertEqual(try library.snapshots(for: document.id).count, 0)
        // The note outlives the sheet; only the attachment goes.
        XCTAssertEqual(try library.note(note.id)?.documentIDs, [])
        XCTAssertEqual(try library.unattachedNotes().map(\.id), [note.id])
    }

    func testDeletingANoteRemovesItFromEverySheetItWasOn() throws {
        let stack = try makeWriterStack()
        let library = stack.library
        let first = try library.createDocument(in: library.inboxGroupID, title: "First")
        let second = try library.createDocument(in: library.inboxGroupID, title: "Second")
        let note = WriterNote(text: "shared thought", source: .intent)
        try library.insert(note)
        try library.attach(note.id, to: first.id, attachment: .routed)
        try library.attach(note.id, to: second.id, attachment: .routed)
        XCTAssertEqual(try library.notes(for: second.id).count, 1)

        try library.delete(note.id)

        XCTAssertEqual(try library.notes(for: first.id).count, 0)
        XCTAssertEqual(try library.notes(for: second.id).count, 0)
        XCTAssertNil(try library.note(note.id))
    }

    func testDetachingLeavesTheNoteOnItsOtherSheets() throws {
        let stack = try makeWriterStack()
        let library = stack.library
        let first = try library.createDocument(in: library.inboxGroupID, title: "First")
        let second = try library.createDocument(in: library.inboxGroupID, title: "Second")
        let note = WriterNote(text: "shared thought", source: .intent)
        try library.insert(note)
        try library.attach(note.id, to: first.id, attachment: .routed)
        try library.attach(note.id, to: second.id, attachment: .routed)

        try library.detach(note.id, from: first.id)

        XCTAssertEqual(try library.notes(for: first.id).count, 0)
        XCTAssertEqual(try library.note(note.id)?.documentIDs, [second.id])
    }

    // MARK: - Trash

    func testTrashRestoreAndEmpty() throws {
        let stack = try makeWriterStack()
        let library = stack.library
        let group = try library.createGroup(name: "Essays", icon: "folder", parent: nil)
        let kept = try library.createDocument(in: group.id, title: "Kept")
        let tossed = try library.createDocument(in: group.id, title: "Tossed")

        try library.trash(tossed.id)
        XCTAssertEqual(try library.documents(in: group.id, sort: .manual).map(\.id), [kept.id])
        XCTAssertEqual(
            try library.documents(in: library.trashGroupID, sort: .manual).map(\.id), [tossed.id])

        try library.restore(tossed.id)
        XCTAssertEqual(
            try library.documents(in: group.id, sort: .titleAscending).map(\.title),
            ["Kept", "Tossed"])
        XCTAssertEqual(try library.documents(in: library.trashGroupID, sort: .manual).count, 0)

        try library.trash(tossed.id)
        try library.emptyTrash()
        XCTAssertNil(try library.document(tossed.id))
        XCTAssertNotNil(try library.document(kept.id))
    }

    func testDeletingAGroupTrashesItsSheetsRatherThanErasingThem() throws {
        let stack = try makeWriterStack()
        let library = stack.library
        let parent = try library.createGroup(name: "Book", icon: "folder", parent: nil)
        let child = try library.createGroup(name: "Chapter", icon: "folder", parent: parent.id)
        let document = try library.createDocument(in: child.id, title: "Scene")

        try library.delete(parent.id)

        XCTAssertEqual(try library.groups().filter { $0.name == "Book" || $0.name == "Chapter" }.count, 0)
        let trashed = try library.documents(in: library.trashGroupID, sort: .manual)
        XCTAssertEqual(trashed.map(\.id), [document.id])
        XCTAssertEqual(trashed.first?.groupID, library.inboxGroupID)
    }

    func testTheTwoSystemGroupsCannotBeDeleted() throws {
        let stack = try makeWriterStack()
        try stack.library.delete(stack.library.inboxGroupID)
        try stack.library.delete(stack.library.trashGroupID)
        XCTAssertEqual(try stack.library.groups().count, 2)
    }

    // MARK: - Move and reorder

    func testMovingASheetRenumbersBothGroups() throws {
        let stack = try makeWriterStack()
        let library = stack.library
        let source = try library.createGroup(name: "Source", icon: "folder", parent: nil)
        let destination = try library.createGroup(name: "Destination", icon: "folder", parent: nil)
        let first = try library.createDocument(in: source.id, title: "One")
        let second = try library.createDocument(in: source.id, title: "Two")
        let third = try library.createDocument(in: source.id, title: "Three")
        let existing = try library.createDocument(in: destination.id, title: "Already here")

        try library.moveDocument(second.id, to: destination.id, at: 0)

        XCTAssertEqual(
            try library.documents(in: source.id, sort: .manual).map(\.title), ["One", "Three"])
        XCTAssertEqual(
            try library.documents(in: source.id, sort: .manual).map(\.sortIndex), [0, 1])
        XCTAssertEqual(
            try library.documents(in: destination.id, sort: .manual).map(\.title),
            ["Two", "Already here"])
        XCTAssertEqual(
            try library.documents(in: destination.id, sort: .manual).map(\.sortIndex), [0, 1])
        XCTAssertEqual(try library.document(first.id)?.groupID, source.id)
        XCTAssertEqual(try library.document(third.id)?.groupID, source.id)
        XCTAssertEqual(try library.document(existing.id)?.groupID, destination.id)
    }

    func testMovingAGroupReparentsItAndRenumbersItsNewSiblings() throws {
        let stack = try makeWriterStack()
        let library = stack.library
        let book = try library.createGroup(name: "Book", icon: "folder", parent: nil)
        let one = try library.createGroup(name: "One", icon: "folder", parent: book.id)
        let two = try library.createGroup(name: "Two", icon: "folder", parent: book.id)
        let loose = try library.createGroup(name: "Loose", icon: "folder", parent: nil)

        try library.moveGroup(loose.id, to: book.id, at: 1)

        let children = try library.groups()
            .filter { $0.parentID == book.id }
            .sorted { $0.sortIndex < $1.sortIndex }
        XCTAssertEqual(children.map(\.name), ["One", "Loose", "Two"])
        XCTAssertEqual(children.map(\.sortIndex), [0, 1, 2])
        XCTAssertEqual(children.map(\.id), [one.id, loose.id, two.id])
    }

    func testAGroupCannotBeMovedInsideItself() throws {
        let stack = try makeWriterStack()
        let library = stack.library
        let parent = try library.createGroup(name: "Parent", icon: "folder", parent: nil)
        let child = try library.createGroup(name: "Child", icon: "folder", parent: parent.id)

        try library.moveGroup(parent.id, to: child.id, at: 0)

        XCTAssertNil(try library.groups().first { $0.id == parent.id }?.parentID)
    }

    // MARK: - Filters

    func testFiltersRoundTripAndTheirKeywordsGoWithThem() throws {
        let stack = try makeWriterStack()
        let library = stack.library
        let scope = try library.createGroup(name: "Essays", icon: "folder", parent: nil)
        let filter = WriterFilter(
            scopeGroupID: scope.id, name: "Unfinished essays",
            predicate: FilterPredicate(
                keywordsAll: ["Draft", "draft", "essay"], searchText: nil,
                favoritesOnly: true, modifiedWithin: 604_800),
            sortIndex: 2)

        try library.save(filter)
        var loaded = try XCTUnwrap(try library.filters().first)
        XCTAssertEqual(loaded.id, filter.id)
        XCTAssertEqual(loaded.scopeGroupID, scope.id)
        XCTAssertEqual(loaded.predicate.keywordsAll, ["draft", "essay"])
        XCTAssertTrue(loaded.predicate.favoritesOnly)
        XCTAssertEqual(loaded.predicate.modifiedWithin, 604_800)

        loaded.name = "Renamed"
        loaded.predicate.keywordsAll = ["essay"]
        try library.save(loaded)
        XCTAssertEqual(try library.filters().count, 1)
        XCTAssertEqual(try library.filters().first?.name, "Renamed")
        XCTAssertEqual(try library.filters().first?.predicate.keywordsAll, ["essay"])

        try library.deleteFilter(loaded.id)
        XCTAssertEqual(try library.filters().count, 0)
    }

    func testAFilterPredicateSelectsBySheetKeywordsFavouriteAndAge() throws {
        let stack = try makeWriterStack()
        let library = stack.library
        let group = try library.createGroup(name: "Essays", icon: "folder", parent: nil)
        var matching = try library.createDocument(in: group.id, title: "Matching")
        matching.keywords = ["draft", "essay"]
        matching.isFavorite = true
        try library.update(matching)
        var wrongKeyword = try library.createDocument(in: group.id, title: "Wrong keyword")
        wrongKeyword.keywords = ["draft"]
        wrongKeyword.isFavorite = true
        try library.update(wrongKeyword)
        var notFavorite = try library.createDocument(in: group.id, title: "Not favourite")
        notFavorite.keywords = ["draft", "essay"]
        try library.update(notFavorite)
        var elsewhere = try library.createDocument(in: library.inboxGroupID, title: "Elsewhere")
        elsewhere.keywords = ["draft", "essay"]
        elsewhere.isFavorite = true
        try library.update(elsewhere)

        let predicate = FilterPredicate(
            keywordsAll: ["draft", "essay"], searchText: nil, favoritesOnly: true,
            modifiedWithin: 3_600)
        XCTAssertEqual(
            try library.documents(matching: predicate, scope: group.id).map(\.title), ["Matching"])
        XCTAssertEqual(
            Set(try library.documents(matching: predicate, scope: nil).map(\.title)),
            ["Matching", "Elsewhere"])

        let stale = FilterPredicate(
            keywordsAll: [], searchText: nil, favoritesOnly: false, modifiedWithin: -1)
        XCTAssertEqual(try library.documents(matching: stale, scope: nil).count, 0)
    }

    func testAFilterScopeIncludesTheGroupsBeneathIt() throws {
        let stack = try makeWriterStack()
        let library = stack.library
        let parent = try library.createGroup(name: "Book", icon: "folder", parent: nil)
        let child = try library.createGroup(name: "Chapter", icon: "folder", parent: parent.id)
        _ = try library.createDocument(in: child.id, title: "Nested")

        XCTAssertEqual(
            try library.documents(matching: FilterPredicate(), scope: parent.id).map(\.title),
            ["Nested"])
    }

    // MARK: - Snapshots

    func testSnapshotsKeepTheNewestTwentyPerSheet() throws {
        let stack = try makeWriterStack()
        let library = stack.library
        let document = try library.createDocument(in: library.inboxGroupID, title: "Revised")
        let other = try library.createDocument(in: library.inboxGroupID, title: "Untouched")
        try library.recordSnapshot("other", for: other.id)

        for index in 1...(DocumentSnapshotLimit.perDocument + 5) {
            try library.recordSnapshot("revision \(index)", for: document.id)
        }

        let snapshots = try library.snapshots(for: document.id)
        XCTAssertEqual(snapshots.count, DocumentSnapshotLimit.perDocument)
        XCTAssertEqual(snapshots.first?.text, "revision \(DocumentSnapshotLimit.perDocument + 5)")
        XCTAssertFalse(snapshots.contains { $0.text == "revision 1" })
        XCTAssertEqual(try library.snapshots(for: other.id).map(\.text), ["other"])
    }

    // MARK: - Change posting

    func testAWriteTellsItsObserversWhatChanged() throws {
        let stack = try makeWriterStack()
        let observer = RecordingLibraryObserver()
        stack.library.addObserver(observer)
        let document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "New")

        let posted = expectation(description: "change posted")
        DispatchQueue.main.async { posted.fulfill() }
        wait(for: [posted], timeout: 2)

        XCTAssertEqual(observer.changes, [.documents(in: stack.library.inboxGroupID)])
        stack.library.removeObserver(observer)
        try stack.library.trash(document.id)
        let settled = expectation(description: "no further change")
        DispatchQueue.main.async { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertEqual(observer.changes.count, 1)
    }
}
