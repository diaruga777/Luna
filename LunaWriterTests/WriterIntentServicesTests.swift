//
//  WriterIntentServicesTests.swift
//  LunaWriterTests
//

import Foundation
import XCTest
@testable import LunaWriterStorage
import LunaWriterModels

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

        XCTAssertEqual(try stack.intents.addNote(text: "   \n ", to: nil), .inbox)
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
}
