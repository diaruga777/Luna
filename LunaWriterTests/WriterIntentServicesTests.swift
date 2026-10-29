//
//  WriterIntentServicesTests.swift
//  LunaWriterTests
//

import Foundation
import XCTest
@testable import LunaWriterStorage
import LunaWriterModels
import LunaAppConfig

final class WriterIntentServicesTests: XCTestCase {

    func testANoteAddressedToASheetGoesThereWhole() throws {
        let stack = try makeWriterStack(embedding: ScriptedEmbedding(fallback: [1, 0]))
        let sheet = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Roof")

        let result = try stack.intents.addNote(text: "  Ask about the gutters.  ", to: sheet.id)

        XCTAssertEqual(result, .document(try XCTUnwrap(try stack.library.document(sheet.id))))
        let notes = try stack.library.notes(for: sheet.id)
        XCTAssertEqual(notes.map(\.text), ["Ask about the gutters."])
        XCTAssertEqual(notes.first?.source, .intent)
        XCTAssertEqual(
            try stack.noteIndex.search(NoteQuery(text: "gutters")).map(\.noteID),
            notes.map(\.id))
    }

    func testANoteAddressedToNoSheetIsRoutedAndTheAnswerNamesWhereItLanded() throws {
        let stack = try makeWriterStack(embedding: ScriptedEmbedding(fallback: [1, 0]))
        let roof = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Roof")
        try stack.documentIndex.index(roof, body: "the roof and its gutters need attention")

        let result = try stack.intents.addNote(text: "ask about the roof gutters", to: nil)

        XCTAssertEqual(result, .document(try XCTUnwrap(try stack.library.document(roof.id))))
        XCTAssertEqual(try stack.library.notes(for: roof.id).count, 1)
    }

    func testWithNoRouterANoteWaitsUnattachedInTheInbox() throws {
        let stack = try makeWriterStack()
        let services = WriterIntentServices(
            library: stack.library, notes: stack.library,
            textStore: stack.textStore, router: nil)

        let result = try services.addNote(text: "a stray thought", to: nil)

        XCTAssertEqual(result, .inbox)
        XCTAssertEqual(try stack.library.unattachedNotes().map(\.text), ["a stray thought"])
    }

    func testAnEmptyNoteIsNotStored() throws {
        let stack = try makeWriterStack(embedding: ScriptedEmbedding(fallback: [1, 0]))

        XCTAssertThrowsError(try stack.intents.addNote(text: "   \n ", to: nil)) { error in
            XCTAssertEqual(error as? WriterIntentServices.Failure, .emptyNote)
        }
        XCTAssertEqual(try stack.library.unattachedNotes().count, 0)
        XCTAssertEqual(
            try stack.library.documents(matching: FilterPredicate(), scope: nil).count, 0)
    }

    func testALongCaptureBecomesSeveralNotes() throws {
        let stack = try makeWriterStack(embedding: ScriptedEmbedding(fallback: [1, 0]))
        let capture = (1...5)
            .map { index in
                (1...4)
                    .map { "Topic \(index) matters in week \($0) of the year." }
                    .joined(separator: " ")
            }
            .joined(separator: "\n\n")

        _ = try stack.intents.addNote(text: capture, to: nil)

        let documents = try stack.library.documents(matching: FilterPredicate(), scope: nil)
        let notes = documents.flatMap { (try? stack.library.notes(for: $0.id)) ?? [] }
        XCTAssertEqual(Set(notes.map(\.id)).count, 5)
    }

    func testCreatingASheetWritesItsFileAndItsHeading() throws {
        let stack = try makeWriterStack(embedding: ScriptedEmbedding(fallback: [1, 0]))
        let group = try stack.library.createGroup(name: "Essays", icon: "folder", parent: nil)

        let document = try stack.intents.createDocument(
            title: "On rivers", text: "They run downhill.", in: group.id)

        XCTAssertEqual(document.title, "On rivers")
        XCTAssertEqual(document.groupID, group.id)
        XCTAssertEqual(document.fileRelativePath, "Essays/On rivers.md")
        XCTAssertEqual(try stack.textStore.loadText(document), "# On rivers\n\nThey run downhill.")
    }

    func testCreatingASheetWithNoTitleLandsInTheInboxUntitled() throws {
        let stack = try makeWriterStack(embedding: ScriptedEmbedding(fallback: [1, 0]))

        let document = try stack.intents.createDocument(title: nil, text: nil, in: nil)

        XCTAssertEqual(document.groupID, stack.library.inboxGroupID)
        XCTAssertFalse(document.title.isEmpty)
    }

    func testRecentSheetsComeBackNewestFirstAndRespectTheLimit() throws {
        let stack = try makeWriterStack(embedding: ScriptedEmbedding(fallback: [1, 0]))
        let first = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "First")
        let second = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Second")
        try stack.library.update(second)
        try stack.library.update(first)

        XCTAssertEqual(try stack.intents.recentDocuments(limit: 1).map(\.title), ["First"])
        XCTAssertEqual(
            try stack.intents.recentDocuments(limit: 10).map(\.title), ["First", "Second"])
    }

    func testATitleSearchMatchesPartOfTheTitleAndIgnoresCase() throws {
        let stack = try makeWriterStack(embedding: ScriptedEmbedding(fallback: [1, 0]))
        _ = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "On rivers")
        _ = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Bread notes")

        XCTAssertEqual(try stack.intents.documents(matchingTitle: "RIVER").map(\.title), ["On rivers"])
        XCTAssertEqual(try stack.intents.documents(matchingTitle: "  ").count, 2)
    }

    func testTheFirstRunAddsAWelcomeSheetAndOnlyEverOne() throws {
        let stack = try makeWriterStack()

        let created = try XCTUnwrap(try stack.bootstrap())
        let again = try stack.bootstrap()

        XCTAssertNil(again)
        XCTAssertEqual(
            try stack.library.documents(matching: FilterPredicate(), scope: nil).map(\.id),
            [created.id])
        XCTAssertEqual(created.groupID, stack.library.inboxGroupID)
        XCTAssertFalse(try stack.textStore.loadText(created).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: stack.libraryRoot.appendingPathComponent(created.fileRelativePath).path))
    }
    func testMissingOrTrashedDestinationDoesNotRerouteNote() throws {
        let stack = try makeWriterStack()
        let document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Sheet")
        try stack.library.trash(document.id)
        for id in [document.id, DocumentID(UUID())] {
            XCTAssertThrowsError(try stack.intents.addNote(text: "Keep this private", to: id)) { error in
                XCTAssertEqual(error as? WriterIntentServices.Failure, .missingDocument)
            }
        }
        XCTAssertTrue(try stack.library.allNotes().isEmpty)
    }

    func testFindAndReadSheetCanResolveAnOlderSheetByStableID() throws {
        let stack = try makeWriterStack()
        let document = try stack.intents.createDocument(title: "Rivers", text: "Flowing water", in: nil)
        XCTAssertEqual(try stack.intents.findDocuments(id: document.id).map(\.id), [document.id])
        XCTAssertEqual(try stack.intents.text(for: document.id), "# Rivers\n\nFlowing water")
        XCTAssertTrue(try stack.intents.findDocuments(search: "missing").isEmpty)
    }

    func testAutomationTracksCommittedObjectsAndSuppressesBookkeepingAndRollback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "WriterAutomationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { try? FileManager.default.removeItem(at: directory); defaults.removePersistentDomain(forName: suite) }
        let journal = AppAutomation(app: .writer, directory: directory, defaults: defaults)
        let stack = try WriterStorageStack(databaseURL: directory.appendingPathComponent("writer.sqlite"),
            libraryRoot: directory.appendingPathComponent("Library"), automationJournal: journal)
        let baseline = try journal.changes().nextToken
        let sheet = try stack.intents.createDocument(title: "Rivers", text: "Water", in: nil)
        let capture = try stack.intents.captureNote(text: "A thought", to: sheet.id)
        let note = try XCTUnwrap(capture.notes.first)
        let events = try journal.changes(after: baseline).changes
        XCTAssertEqual(events.map(\.notificationTitle), ["Luna.writer.document.created", "Luna.writer.document.updated", "Luna.writer.note.created"])
        XCTAssertEqual(events.last?.itemID, note.id.rawValue.uuidString)
        let token = try journal.changes().nextToken
        try stack.library.setFavorite(false, for: sheet.id)
        XCTAssertTrue(try journal.changes(after: token).changes.isEmpty)
        enum Rejected: Error { case edit }
        XCTAssertThrowsError(try stack.database.transaction { db in
            try db.execute("UPDATE documents SET title = 'Never committed'")
            throw Rejected.edit
        })
        XCTAssertTrue(try journal.changes(after: token).changes.isEmpty)
        _ = try stack.intents.updateNote(note.id, text: "Another thought")
        try stack.intents.deleteNotes([note.id])
        XCTAssertEqual(try journal.changes(after: token).changes.map(\.operation), ["updated", "deleted"])
    }

}
