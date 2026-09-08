//
//  WriterDatabaseTests.swift
//  LunaWriterTests
//

import Foundation
import XCTest
@testable import LunaWriterStorage
import LunaWriterModels
import SQLite3

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

    // MARK: - Schema migration

    func testMigratingFromSchemaVersionOneAddsTheVersionTwoChangesWithoutLosingRows() throws {
        let root = try makeWriterTemporaryDirectory()
        let url = root.appendingPathComponent("writer.sqlite")
        let documentID = "AAAAAAAA-0000-4000-8000-000000000001"

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let raw = try XCTUnwrap(handle)
        executeRaw(
            """
            CREATE TABLE groups (id TEXT PRIMARY KEY, parent_id TEXT, name TEXT NOT NULL,
                icon TEXT NOT NULL DEFAULT 'folder', sort_index INTEGER NOT NULL DEFAULT 0,
                kind TEXT NOT NULL DEFAULT 'user', created_at REAL NOT NULL, updated_at REAL NOT NULL);
            CREATE TABLE documents (id TEXT PRIMARY KEY, group_id TEXT NOT NULL,
                title TEXT NOT NULL DEFAULT '', snippet TEXT NOT NULL DEFAULT '',
                sort_index INTEGER NOT NULL DEFAULT 0, favorite INTEGER NOT NULL DEFAULT 0,
                goal_unit TEXT, goal_target INTEGER, goal_mode TEXT,
                file_path TEXT NOT NULL DEFAULT '', word_count INTEGER NOT NULL DEFAULT 0,
                char_count INTEGER NOT NULL DEFAULT 0, revision INTEGER NOT NULL DEFAULT 0,
                created_at REAL NOT NULL, updated_at REAL NOT NULL, trashed_at REAL);
            CREATE TABLE authorship_spans (document_id TEXT NOT NULL, start INTEGER NOT NULL,
                end INTEGER NOT NULL, source TEXT NOT NULL DEFAULT 'author', model TEXT,
                created_at REAL NOT NULL);
            CREATE TABLE document_keywords (document_id TEXT NOT NULL, keyword TEXT NOT NULL,
                PRIMARY KEY (document_id, keyword));
            CREATE TABLE annotations (id TEXT PRIMARY KEY, document_id TEXT NOT NULL,
                kind TEXT NOT NULL DEFAULT 'comment', source TEXT NOT NULL DEFAULT 'manual',
                note_id TEXT, anchor_start INTEGER NOT NULL DEFAULT 0,
                anchor_end INTEGER NOT NULL DEFAULT 0, anchor_exact TEXT NOT NULL DEFAULT '',
                anchor_prefix TEXT NOT NULL DEFAULT '', anchor_suffix TEXT NOT NULL DEFAULT '',
                created_at REAL NOT NULL);
            INSERT INTO groups (id, parent_id, name, icon, sort_index, kind, created_at, updated_at)
                VALUES ('11B00000-0000-4000-8000-000000000001', NULL, 'Inbox', 'tray', 0, 'inbox', 0, 0);
            INSERT INTO documents (id, group_id, title, file_path, created_at, updated_at)
                VALUES ('\(documentID)', '11B00000-0000-4000-8000-000000000001', 'Kept', 'Kept.md', 0, 0);
            INSERT INTO authorship_spans (document_id, start, end, source, created_at)
                VALUES ('\(documentID)', 0, 4, 'author', 0);
            PRAGMA user_version = 1;
            """, in: raw)
        sqlite3_close(raw)

        let database = try WriterDatabase(fileURL: url)
        XCTAssertEqual(database.userVersion, WriterDatabase.schemaVersion)
        let library = try SQLiteWriterLibrary(database: database)

        let document = try XCTUnwrap(try library.document(DocumentID(XCTUnwrap(UUID(uuidString: documentID)))))
        XCTAssertEqual(document.title, "Kept")
        XCTAssertEqual(document.sentenceCount, 0, "the new column defaults to 0 on an existing row")
        let marks = try library.marks(for: document.id)
        XCTAssertEqual(marks.authorship.map(\.range), [TextRange(start: 0, end: 4)])

        try database.perform { db in
            XCTAssertNotNil(try db.scalarInt(
                "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = 'documents_file_path'"))
            XCTAssertNotNil(try db.scalarInt(
                "SELECT 1 FROM pragma_table_info('authorship_spans') WHERE name = 'end_offset'"))
            XCTAssertNil(try db.scalarInt(
                "SELECT 1 FROM pragma_table_info('authorship_spans') WHERE name = 'end'"))
        }
    }

    private func executeRaw(_ sql: String, in db: OpaquePointer) {
        var message: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &message)
        let detail = message.map { String(cString: $0) } ?? ""
        sqlite3_free(message)
        XCTAssertEqual(status, SQLITE_OK, "\(sql) — \(detail)")
    }

    // MARK: - Statement cache

    func testTheStatementCacheStaysBoundedAfterLoadingManyDistinctDocuments() throws {
        let stack = try makeWriterStack()
        var ids: [DocumentID] = []
        for index in 0..<200 {
            let document = try stack.library.createDocument(
                in: stack.library.inboxGroupID, title: "Sheet \(index)")
            ids.append(document.id)
        }

        // Each fetch used to interpolate that one document's id into the
        // keyword-lookup SQL, minting a permanently cached statement per id.
        for id in ids { _ = try stack.library.document(id) }

        try stack.database.perform { db in
            XCTAssertLessThan(db.statementCacheCountForTesting, 40)
        }
    }

    // MARK: - Concurrency

    func testPerformFromSeveralQueuesAtOnceSerialisesWithoutLosingWrites() throws {
        let stack = try makeWriterStack()
        let queues = (0..<8).map { DispatchQueue(label: "writer-database-test-\($0)") }
        let group = DispatchGroup()
        for (index, queue) in queues.enumerated() {
            group.enter()
            queue.async {
                for sheet in 0..<10 {
                    _ = try? stack.library.createDocument(
                        in: stack.library.inboxGroupID, title: "Q\(index)-\(sheet)")
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)

        let count = try stack.library.documents(
            in: stack.library.inboxGroupID, sort: .manual
        ).count
        XCTAssertEqual(count, 80)
    }

    // MARK: - Search stays current

    func testUpdatingADocumentReindexesItsTitleForSearch() throws {
        let stack = try makeWriterStack(embedding: ScriptedEmbedding(fallback: [1, 0]))
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Plain")
        try stack.textStore.saveText("nothing about it yet", for: &document)
        XCTAssertEqual(try stack.library.searchDocuments("marigold", limit: 10).count, 0)

        document.title = "Marigold notes"
        try stack.library.update(document)

        XCTAssertEqual(
            try stack.library.searchDocuments("marigold", limit: 10).map(\.documentID), [document.id])
        XCTAssertEqual(
            try stack.library.searchDocuments("nothing", limit: 10).map(\.documentID), [document.id],
            "the saved body survives a metadata-only update")
    }

    func testSettingKeywordsReindexesWithoutLosingTheSavedBody() throws {
        let stack = try makeWriterStack(embedding: ScriptedEmbedding(fallback: [1, 0]))
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Plain")
        try stack.textStore.saveText("a paragraph about ferries", for: &document)

        try stack.library.setKeywords(["harbourfront"], for: document.id)

        XCTAssertEqual(
            try stack.library.searchDocuments("harbourfront", limit: 10).map(\.documentID), [document.id])
        XCTAssertEqual(
            try stack.library.searchDocuments("ferries", limit: 10).map(\.documentID), [document.id],
            "the saved body, read back through the text store, survives a metadata-only reindex")
    }

    // MARK: - Revision conflicts

    func testAStaleFullUpdateIsRejectedRatherThanClobberingANewerSave() throws {
        let stack = try makeWriterStack()
        let created = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Draft")
        // One holder saves new text through the text store, which bumps the
        // file path and the revision.
        var saved = created
        try stack.textStore.saveText("# Renamed\n\nBody.", for: &saved)

        // A second holder still has the pre-save copy and only meant to flip
        // one field via the old full-row `update`.
        var stale = created
        stale.isFavorite = true

        XCTAssertThrowsError(try stack.library.update(stale)) { error in
            XCTAssertEqual(error as? WriterLibraryConflictError, WriterLibraryConflictError(id: created.id))
        }
        XCTAssertEqual(try stack.library.document(created.id)?.fileRelativePath, saved.fileRelativePath)
    }

    func testSetFavoriteNeverConflictsWithAConcurrentSave() throws {
        let stack = try makeWriterStack()
        let created = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Draft")
        var saved = created
        try stack.textStore.saveText("# Renamed\n\nBody.", for: &saved)

        try stack.library.setFavorite(true, for: created.id)

        let after = try XCTUnwrap(try stack.library.document(created.id))
        XCTAssertTrue(after.isFavorite)
        XCTAssertEqual(after.fileRelativePath, saved.fileRelativePath)
    }

    // MARK: - Snapshots

    func testSnapshotCountMatchesTheFullList() throws {
        let stack = try makeWriterStack()
        let document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Log")
        for index in 1...5 { try stack.library.recordSnapshot("revision \(index)", for: document.id) }

        XCTAssertEqual(try stack.library.snapshotCount(for: document.id), 5)
        XCTAssertEqual(
            try stack.library.snapshotSummaries(for: document.id).map(\.characterCount),
            try stack.library.snapshots(for: document.id).map(\.text.count))
    }

    // MARK: - Lookup by path

    func testDocumentAtPathFindsTheRowByItsFilePath() throws {
        let stack = try makeWriterStack()
        var document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Found")
        try stack.textStore.saveText("body", for: &document)

        XCTAssertEqual(try stack.library.document(atPath: document.fileRelativePath)?.id, document.id)
        XCTAssertNil(try stack.library.document(atPath: "nothing/here.md"))
    }
}
