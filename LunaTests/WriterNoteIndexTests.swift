//
//  WriterNoteIndexTests.swift
//  LunaTests
//

import Foundation
import XCTest
@testable import LunaWriterStorage
import LunaWriterModels

final class WriterNoteIndexTests: XCTestCase {

    // MARK: - Query building

    func testTheLastTokenMatchesAsAPrefixOnlyWhileItIsBeingTyped() throws {
        let stack = try makeWriterStack()
        try insert("the harbour lights at dusk", in: stack)

        let typing = NoteQuery(text: "harb", prefixMatchesLastToken: true)
        XCTAssertEqual(try stack.noteIndex.search(typing).count, 1)

        let finished = NoteQuery(text: "harb", prefixMatchesLastToken: false)
        XCTAssertEqual(try stack.noteIndex.search(finished).count, 0)
    }

    func testTokensAreOrJoinedSoOneWordIsEnoughToRecallANote() throws {
        let stack = try makeWriterStack()
        let sailing = try insert("sailing without a motor", in: stack)
        let harbour = try insert("the harbour lights at dusk", in: stack)
        try insert("a recipe for bread", in: stack)

        let hits = try stack.noteIndex.search(NoteQuery(text: "sailing harbour"))

        XCTAssertEqual(Set(hits.map(\.noteID)), [sailing, harbour])
    }

    func testAQueryOfPunctuationAloneFindsNothingRatherThanEverything() throws {
        let stack = try makeWriterStack()
        try insert("the harbour lights at dusk", in: stack)

        XCTAssertEqual(try stack.noteIndex.search(NoteQuery(text: "  ?? -- ")).count, 0)
    }

    func testSearchCanBeScopedToOneSheet() throws {
        let stack = try makeWriterStack()
        let library = stack.library
        let mine = try library.createDocument(in: library.inboxGroupID, title: "Mine")
        let other = try library.createDocument(in: library.inboxGroupID, title: "Other")
        let onMine = try insert("harbour lights", in: stack, on: mine.id)
        try insert("harbour walls", in: stack, on: other.id)

        let hits = try stack.noteIndex.search(NoteQuery(text: "harbour", scope: .document(mine.id)))

        XCTAssertEqual(hits.map(\.noteID), [onMine])
    }

    /// The "@" overlay marks a hit "from another document" when the open
    /// sheet is not among its `documentIDs`; hits that carried none marked
    /// every note that way, including the sheet's own.
    func testAHitNamesTheSheetsItsNoteSitsOn() throws {
        let stack = try makeWriterStack()
        let library = stack.library
        let mine = try library.createDocument(in: library.inboxGroupID, title: "Mine")
        let onMine = try insert("harbour lights", in: stack, on: mine.id)

        let hit = try XCTUnwrap(stack.noteIndex.search(NoteQuery(text: "harbour")).first)

        XCTAssertEqual(hit.noteID, onMine)
        XCTAssertEqual(hit.documentIDs, [mine.id])
        XCTAssertEqual(hit.noteText, "harbour lights")
    }

    // MARK: - Hybrid ordering

    func testMeaningOutranksWordOverlapOnceTheQueryIsLongEnough() throws {
        let embedding = ScriptedEmbedding()
        let stack = try makeWriterStack(embedding: embedding)
        let aboutMigration = "migration of the humpback whale across the pacific"
        let wordMatch = "north routes migration"
        let query = "routes north migration"
        embedding.exact[aboutMigration] = [1, 0]
        embedding.exact[query] = [1, 0]
        embedding.exact[wordMatch] = [0, 1]

        let meaningful = try insert(aboutMigration, in: stack)
        let literal = try insert(wordMatch, in: stack)

        let lexicalOnly = SQLiteNoteIndex(database: stack.database, embedding: nil)
        XCTAssertEqual(
            try lexicalOnly.search(NoteQuery(text: query)).first?.noteID, literal,
            "with words alone the note sharing all three terms should win")

        let fused = try stack.noteIndex.search(NoteQuery(text: query))
        XCTAssertEqual(fused.first?.noteID, meaningful)
        XCTAssertGreaterThan(fused[0].score, fused[1].score)
    }

    func testATwoTokenQueryIsScoredOnWordsAlone() throws {
        let embedding = ScriptedEmbedding()
        let stack = try makeWriterStack(embedding: embedding)
        let aboutMigration = "migration of the humpback whale across the pacific"
        let wordMatch = "north routes migration"
        embedding.exact[aboutMigration] = [1, 0]
        embedding.exact[wordMatch] = [0, 1]
        embedding.exact["north migration"] = [1, 0]
        _ = try insert(aboutMigration, in: stack)
        _ = try insert(wordMatch, in: stack)
        let lexicalOnly = SQLiteNoteIndex(database: stack.database, embedding: nil)

        let short = NoteQuery(text: "north migration")
        XCTAssertEqual(
            try stack.noteIndex.search(short).map(\.score),
            try lexicalOnly.search(short).map(\.score),
            "under three tokens a sentence vector says nothing the words did not")

        let long = NoteQuery(text: "north routes migration")
        XCTAssertNotEqual(
            try stack.noteIndex.search(long).map(\.score),
            try lexicalOnly.search(long).map(\.score))
    }

    func testAHitCarriesASnippetOfTheNote() throws {
        let stack = try makeWriterStack()
        try insert("the harbour lights at dusk over the water", in: stack)

        let snippet = try XCTUnwrap(
            try stack.noteIndex.search(NoteQuery(text: "harbour")).first?.snippet)

        XCTAssertTrue(snippet.contains("harbour"), snippet)
    }

    // MARK: - Related

    func testRelatedScoresTheTrailingSentenceAsWellAsTheWholeWindow() throws {
        let embedding = ScriptedEmbedding()
        let stack = try makeWriterStack(embedding: embedding)
        let library = stack.library
        let document = try library.createDocument(in: library.inboxGroupID, title: "Draft")
        let aboutTheTail = "ferrets sleep for eighteen hours a day"
        let aboutNothing = "the price of tin in 1904"
        embedding.exact[aboutTheTail] = [0, 1]
        embedding.exact[aboutNothing] = [1, 0]
        let tailNote = try insert(aboutTheTail, in: stack, on: document.id)
        let unrelated = try insert(aboutNothing, in: stack, on: document.id)

        let window = String(repeating: "alpha ", count: 60) + "and then the ferrets arrived"
        let tail = String(window.suffix(SQLiteNoteIndex.relatedTailLength))
        embedding.exact[window] = [1, 0]
        embedding.exact[tail] = [0, 1]

        let hits = try stack.noteIndex.related(to: window, in: document.id, limit: 5)

        let byNote = Dictionary(uniqueKeysWithValues: hits.map { ($0.noteID, $0.score) })
        XCTAssertGreaterThan(try XCTUnwrap(byNote[tailNote]), 0.9)
        XCTAssertEqual(try XCTUnwrap(byNote[unrelated]), 1.0, accuracy: 0.001)
        XCTAssertEqual(hits.count, 2)
    }

    func testRelatedOnlySeesNotesOnTheSheetAsked() throws {
        let embedding = ScriptedEmbedding(fallback: [1, 0])
        let stack = try makeWriterStack(embedding: embedding)
        let library = stack.library
        let mine = try library.createDocument(in: library.inboxGroupID, title: "Mine")
        let other = try library.createDocument(in: library.inboxGroupID, title: "Other")
        let onMine = try insert("a note here", in: stack, on: mine.id)
        try insert("a note there", in: stack, on: other.id)

        XCTAssertEqual(
            try stack.noteIndex.related(to: "some text", in: mine.id, limit: 5).map(\.noteID),
            [onMine])
    }

    func testRelatedReturnsNothingWithoutAnEmbeddingModel() throws {
        let stack = try makeWriterStack(embedding: nil)
        let document = try stack.library.createDocument(
            in: stack.library.inboxGroupID, title: "Draft")
        try insert("a note here", in: stack, on: document.id)

        XCTAssertEqual(try stack.noteIndex.related(to: "some text", in: document.id, limit: 5), [])
    }

    // MARK: - Maintenance

    func testRemovingANoteFromTheIndexTakesItOutOfSearch() throws {
        let stack = try makeWriterStack()
        let id = try insert("the harbour lights", in: stack)
        XCTAssertEqual(try stack.noteIndex.search(NoteQuery(text: "harbour")).count, 1)

        try stack.noteIndex.remove(id)

        XCTAssertEqual(try stack.noteIndex.search(NoteQuery(text: "harbour")).count, 0)
    }

    func testIndexingTheSameNoteTwiceLeavesOneHit() throws {
        let stack = try makeWriterStack()
        let id = try insert("the harbour lights", in: stack)
        let note = try XCTUnwrap(try stack.library.note(id))

        try stack.noteIndex.index(note)
        try stack.noteIndex.index(note)

        XCTAssertEqual(try stack.noteIndex.search(NoteQuery(text: "harbour")).count, 1)
    }

    func testRebuildRestoresSearchAfterTheIndexIsEmptied() throws {
        let stack = try makeWriterStack()
        let id = try insert("the harbour lights", in: stack)
        try stack.noteIndex.remove(id)
        XCTAssertEqual(try stack.noteIndex.search(NoteQuery(text: "harbour")).count, 0)

        try stack.noteIndex.rebuild()

        XCTAssertEqual(try stack.noteIndex.search(NoteQuery(text: "harbour")).map(\.noteID), [id])
    }

    func testIndexingANoteWithNoRowThrowsRatherThanIndexingNothing() throws {
        let stack = try makeWriterStack()
        let ghost = WriterNote(text: "never inserted", source: .typed)

        XCTAssertThrowsError(try stack.noteIndex.index(ghost)) { error in
            XCTAssertEqual(error as? NoteIndexMissingRowError, NoteIndexMissingRowError(id: ghost.id))
        }
    }

    func testRebuildWithNoEmbeddingModelKeepsExistingEmbeddings() throws {
        let embedding = ScriptedEmbedding(fallback: [1, 0])
        let stack = try makeWriterStack(embedding: embedding)
        let id = try insert("the harbour lights", in: stack)
        let embeddedCount: () throws -> Int64 = {
            try stack.database.perform { db in
                (try db.scalarInt(
                    "SELECT COUNT(*) FROM note_embeddings WHERE note_id = ?"
                ) { try $0.bind(1, id.rawValue.uuidString) }) ?? 0
            }
        }
        XCTAssertEqual(try embeddedCount(), 1)

        // A build with no embedding model must not erase a vector an earlier
        // (or later) build with the model can still use.
        let lexicalOnly = SQLiteNoteIndex(database: stack.database, embedding: nil)
        try lexicalOnly.rebuild()

        XCTAssertEqual(try embeddedCount(), 1)
    }

    func testRebuildWithAnUnavailableModelKeepsExistingEmbeddings() throws {
        let embedding = ScriptedEmbedding(fallback: [1, 0])
        let stack = try makeWriterStack(embedding: embedding)
        let id = try insert("the harbour lights", in: stack)
        let embeddedCount: () throws -> Int64 = {
            try stack.database.perform { db in
                (try db.scalarInt(
                    "SELECT COUNT(*) FROM note_embeddings WHERE note_id = ?"
                ) { try $0.bind(1, id.rawValue.uuidString) }) ?? 0
            }
        }
        XCTAssertEqual(try embeddedCount(), 1)

        // An embedding that is configured but reports no working model
        // (dimensions 0, e.g. the language has no on-device model) must be
        // treated the same as no embedding at all: rebuild must not erase a
        // vector an earlier build with a working model wrote.
        let unavailable = ScriptedEmbedding(dimensions: 0)
        let stillLexicalOnly = SQLiteNoteIndex(database: stack.database, embedding: unavailable)
        try stillLexicalOnly.rebuild()

        XCTAssertEqual(try embeddedCount(), 1)
    }

    // MARK: - Reindexing on update

    func testUpdatingANoteRefreshesWhatRelatedSees() throws {
        let embedding = ScriptedEmbedding()
        let stack = try makeWriterStack(embedding: embedding)
        let document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: "Draft")
        let originalText = "a note about the weather"
        embedding.exact[originalText] = [1, 0]
        let note = WriterNote(documentIDs: [document.id], text: originalText, source: .typed)
        try stack.library.insert(note)

        let window = "something about ferries and the tide"
        embedding.exact[window] = [0, 1]
        let tail = String(window.suffix(SQLiteNoteIndex.relatedTailLength))
        embedding.exact[tail] = [0, 1]
        let before = try stack.noteIndex.related(to: window, in: document.id, limit: 5).first?.score
        XCTAssertEqual(before ?? 0, 0, accuracy: 0.001, "the stale weather note reads as unrelated")

        var edited = note
        edited.text = window
        try stack.library.update(edited)

        let after = try stack.noteIndex.related(to: window, in: document.id, limit: 5)
        XCTAssertEqual(after.first?.noteID, note.id)
        XCTAssertEqual(after.first?.score ?? 0, 1.0, accuracy: 0.001)
    }

    // MARK: - Helpers

    @discardableResult
    private func insert(
        _ text: String, in stack: WriterStorageStack, on document: DocumentID? = nil
    ) throws -> NoteID {
        let note = WriterNote(
            documentIDs: document.map { [$0] } ?? [], text: text, source: .typed)
        try stack.library.insert(note)
        try stack.noteIndex.index(note)
        return note.id
    }
}
