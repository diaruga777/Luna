//
//  NoteRouterTests.swift
//  LunaWriterTests
//

import Foundation
import XCTest
@testable import LunaWriterStorage
import LunaWriterModels

final class NoteRouterTests: XCTestCase {

    func testAnExplicitPhraseMakesANewSheetTitledFromWhatFollowsIt() throws {
        let stack = try makeWriterStack(embedding: ScriptedEmbedding(fallback: [1, 0]))
        _ = try sheet("Bread notes", body: "sourdough starter and flour", in: stack)

        let placements = try stack.router.route("new document: bread notes for the winter bake")

        XCTAssertEqual(placements.count, 1)
        let placement = try XCTUnwrap(placements.first)
        XCTAssertTrue(placement.created)
        XCTAssertEqual(placement.title, "Bread Notes For The Winter Bake")
        XCTAssertEqual(try stack.library.document(placement.documentID)?.groupID,
                       stack.library.inboxGroupID)
    }

    func testAnExplicitPhraseWinsOverASheetThatWouldHaveMatched() throws {
        let stack = try makeWriterStack(embedding: ScriptedEmbedding(fallback: [1, 0]))
        let existing = try sheet("Bread notes", body: "sourdough starter and flour", in: stack)

        let placements = try stack.router.route("new document: sourdough starter and flour")

        XCTAssertEqual(placements.count, 1)
        XCTAssertNotEqual(placements.first?.documentID, existing.id)
        XCTAssertEqual(placements.first?.created, true)
    }

    func testACaptureCanLandOnTwoStronglyRelatedSheets() throws {
        let embedding = ScriptedEmbedding()
        let stack = try makeWriterStack(embedding: embedding)
        let capture = "the humpback whales migrate along the pacific coast"
        embedding.exact[capture] = [1, 0]

        let whales = try sheet(
            "Whale migration", body: "notes about humpback whales and the pacific",
            summaryVector: [1, 0], embedding: embedding, in: stack)
        let coast = try sheet(
            "Pacific coast trip", body: "the coast road and its pacific views",
            summaryVector: [1, 0], embedding: embedding, in: stack)
        let unrelated = try sheet(
            "Bread recipes", body: "flour water salt and time",
            summaryVector: [0, 1], embedding: embedding, in: stack)
        let wrongMeaning = try sheet(
            "Coastal geology", body: "the pacific plate and the coast shelf",
            summaryVector: [0, 1], embedding: embedding, in: stack)

        let placements = try stack.router.route(capture)

        XCTAssertEqual(Set(placements.map(\.documentID)), [whales.id, coast.id])
        XCTAssertTrue(placements.allSatisfy { !$0.created })
        XCTAssertFalse(placements.contains { $0.documentID == unrelated.id })
        XCTAssertFalse(placements.contains { $0.documentID == wrongMeaning.id })
    }

    func testEverySheetBelowTheThresholdMeansANewSheetTitledFromSixWords() throws {
        let embedding = ScriptedEmbedding()
        let stack = try makeWriterStack(embedding: embedding)
        _ = try sheet(
            "Bread recipes", body: "flour water salt and time",
            summaryVector: [0, 1], embedding: embedding, in: stack)
        let capture = "buy more olive oil for the kitchen tomorrow"
        embedding.exact[capture] = [1, 0]

        let placements = try stack.router.route(capture)

        XCTAssertEqual(placements.count, 1)
        XCTAssertEqual(placements.first?.created, true)
        XCTAssertEqual(placements.first?.title, "Buy More Olive Oil For The")
    }

    func testASheetTheRouterJustMadeIsVisibleToTheNextCapture() throws {
        let stack = try makeWriterStack(embedding: ScriptedEmbedding(fallback: [1, 0]))
        let capture = "buy more olive oil for the kitchen tomorrow"

        let first = try stack.router.route(capture)
        let second = try stack.router.route(capture)

        XCTAssertEqual(first.first?.created, true)
        XCTAssertEqual(second.first?.created, false)
        XCTAssertEqual(second.first?.documentID, first.first?.documentID)
    }

    func testAnEmptyCaptureIsRoutedNowhere() throws {
        let stack = try makeWriterStack(embedding: ScriptedEmbedding(fallback: [1, 0]))
        XCTAssertEqual(try stack.router.route("   \n  ").count, 0)
    }

    func testATrashedSheetIsNeverACandidate() throws {
        let stack = try makeWriterStack(embedding: ScriptedEmbedding(fallback: [1, 0]))
        let bread = try sheet("Bread notes", body: "sourdough starter and flour", in: stack)
        try stack.library.trash(bread.id)

        let placements = try stack.router.route("more sourdough starter and flour today")

        XCTAssertEqual(placements.first?.created, true)
        XCTAssertNotEqual(placements.first?.documentID, bread.id)
    }

    func testSharedCommonWordsDoNotTurnWeakSimilarityIntoAnAttachment() throws {
        let embedding = ScriptedEmbedding()
        let stack = try makeWriterStack(embedding: embedding)
        let capture = "why not offer a happy hour discount in the app"
        embedding.exact[capture] = [1, 0]
        _ = try sheet("Why is drug addiction bad", body: "why is the self divided",
                      summaryVector: vector(cosine: 0.33), embedding: embedding, in: stack)
        _ = try sheet("Welcome to Luna Writer", body: "in the app",
                      summaryVector: vector(cosine: 0.31), embedding: embedding, in: stack)

        let placements = try stack.router.route(capture)

        XCTAssertEqual(placements.count, 1)
        XCTAssertEqual(placements.first?.created, true)
    }

    func testSemanticParaphrasesCanMatchWithoutAnySharedSearchTokens() throws {
        let embedding = ScriptedEmbedding()
        let stack = try makeWriterStack(embedding: embedding)
        let capture = "Save audio episodes for offline listening while travelling"
        embedding.exact[capture] = [1, 0]
        let document = try sheet("Download podcasts before flights", body: "",
                                 summaryVector: vector(cosine: 0.58), embedding: embedding, in: stack)
        XCTAssertTrue(try stack.documentIndex.search(capture, limit: 5).isEmpty)

        XCTAssertEqual(try stack.router.route(capture).map(\.documentID), [document.id])
    }

    func testSecondaryAttachmentsNeedBothStrongSimilarityAndProximityToTheBestMatch() throws {
        let embedding = ScriptedEmbedding()
        let stack = try makeWriterStack(embedding: embedding)
        let capture = "a capture about ocean wildlife"
        embedding.exact[capture] = [1, 0]
        let best = try sheet("Whale migration", body: "",
                             summaryVector: vector(cosine: 0.65), embedding: embedding, in: stack)
        let close = try sheet("Ocean mammals", body: "",
                              summaryVector: vector(cosine: 0.63), embedding: embedding, in: stack)
        _ = try sheet("Third strong match", body: "",
                      summaryVector: vector(cosine: 0.62), embedding: embedding, in: stack)
        _ = try sheet("More distant topic", body: "",
                      summaryVector: vector(cosine: 0.55), embedding: embedding, in: stack)

        XCTAssertEqual(try stack.router.route(capture).map(\.documentID), [best.id, close.id])
    }

    func testAModerateSecondMatchIsNotAttachedEvenWhenCloseToTheBest() throws {
        let embedding = ScriptedEmbedding()
        let stack = try makeWriterStack(embedding: embedding)
        let capture = "a capture about ocean wildlife"
        embedding.exact[capture] = [1, 0]
        let best = try sheet("Whale migration", body: "",
                             summaryVector: vector(cosine: 0.46), embedding: embedding, in: stack)
        _ = try sheet("Pacific coast trip", body: "",
                      summaryVector: vector(cosine: 0.43), embedding: embedding, in: stack)

        XCTAssertEqual(try stack.router.route(capture).map(\.documentID), [best.id])
    }

    func testLexicalSearchAloneCannotMakeAnAutomaticAttachment() throws {
        let stack = try makeWriterStack()
        _ = try sheet("Why is drug addiction bad", body: "why is the self divided", in: stack)
        XCTAssertFalse(try stack.documentIndex.search("why is the app discounted", limit: 5).isEmpty)

        XCTAssertEqual(try stack.router.route("why is the app discounted").first?.created, true)
    }

    func testRoutingIgnoresVectorsFromADifferentModel() throws {
        let embedding = ScriptedEmbedding(fallback: [1, 0])
        let stack = try makeWriterStack(embedding: embedding)
        _ = try sheet("Ocean wildlife", body: "", in: stack)
        try stack.database.transaction { db in
            try db.execute("UPDATE document_embeddings SET model_version = 'old-model'")
        }

        XCTAssertEqual(try stack.router.route("more about ocean wildlife").first?.created, true)
    }

    func testRefreshingOldLinksPrunesOnlyUnrelatedAutomaticAttachments() throws {
        let embedding = ScriptedEmbedding()
        let stack = try makeWriterStack(embedding: embedding)
        let text = "Happy hour discounts for premium subscriptions"
        embedding.exact[text] = [1, 0]
        let unrelated = try sheet("Drug addiction", body: "",
                                  summaryVector: vector(cosine: 0.26), embedding: embedding, in: stack)
        let related = try sheet("Surprise subscription sale", body: "",
                                summaryVector: vector(cosine: 0.56), embedding: embedding, in: stack)
        let auto = WriterNote(text: text)
        try stack.library.insert(auto)
        try stack.library.attach(auto.id, to: unrelated.id, attachment: .routed)
        try stack.library.attach(auto.id, to: related.id, attachment: .routed)
        var protectedIDs: [NoteID] = []
        for reason in [NoteAttachment.manual, .created, .mention, .voice] {
            let note = WriterNote(text: text)
            try stack.library.insert(note)
            try stack.library.attach(note.id, to: unrelated.id, attachment: reason)
            protectedIDs.append(note.id)
        }
        let anchored = WriterNote(documentIDs: [unrelated.id], text: text,
                                  anchor: TextAnchor(start: 0, end: 4, exact: "Drug"))
        try stack.library.insert(anchored)
        try stack.library.attach(anchored.id, to: unrelated.id, attachment: .routed)
        protectedIDs.append(anchored.id)
        let observer = RecordingLibraryObserver()
        stack.library.addObserver(observer)

        try stack.refreshAutomaticNoteLinks()
        try stack.refreshAutomaticNoteLinks()

        XCTAssertEqual(try stack.library.note(auto.id)?.documentIDs, [related.id])
        XCTAssertEqual(Set(try stack.library.notes(for: unrelated.id).map(\.id)), Set(protectedIDs))
        XCTAssertEqual(try stack.library.allNotes().count, 6)
        let delivered = expectation(description: "link cleanup notification")
        DispatchQueue.main.async { delivered.fulfill() }
        wait(for: [delivered], timeout: 2)
        XCTAssertEqual(observer.changes, [.notes(nil)])
    }

    func testRefreshingLinksLeavesIncompatibleEmbeddingsAlone() throws {
        let embedding = ScriptedEmbedding(fallback: [1, 0])
        let stack = try makeWriterStack(embedding: embedding)
        let document = try sheet("A different subject", body: "", in: stack)
        let note = WriterNote(text: "A capture about something else")
        try stack.library.insert(note)
        try stack.library.attach(note.id, to: document.id, attachment: .routed)
        try stack.database.transaction { db in
            try db.execute("UPDATE document_embeddings SET model_version = 'old-model'")
        }

        try stack.refreshAutomaticNoteLinks()

        XCTAssertEqual(try stack.library.note(note.id)?.documentIDs, [document.id])
    }

    func testOnDeviceModelSeparatesUnrelatedTopicsAndRecognizesAParaphrase() throws {
        let embedding = NLSentenceEmbedding()
        guard embedding.dimensions > 0 else { throw XCTSkip("English sentence model unavailable") }
        let stack = try makeWriterStack(embedding: embedding)
        _ = try sheet("Why is drug addiction bad? Why do conflicting desires matter?", body: "", in: stack)
        _ = try sheet("Welcome to Luna Writer", body: "", in: stack)
        _ = try sheet("Laws on emergent properties and intelligence", body: "", in: stack)
        let sale = try sheet("Offer a surprise sale on premium subscriptions for an hour each evening.",
                             body: "", in: stack)
        let capture = "Happy hour in app purchase discount at random time cuz funny and why not"

        XCTAssertEqual(try stack.router.route(capture).map(\.documentID), [sale.id])

        let podcasts = try sheet("Download podcasts before the flight", body: "", in: stack)
        XCTAssertEqual(try stack.router.route(
            "Save audio episodes for offline listening while travelling").map(\.documentID), [podcasts.id])
    }

    /// Unit vectors let the tests exercise the real boundary, not just 0/1.
    private func vector(cosine: Double) -> [Float] {
        [Float(cosine), Float(sqrt(1 - cosine * cosine))]
    }

    // MARK: - Helpers

    @discardableResult
    private func sheet(
        _ title: String, body: String, summaryVector: [Float]? = nil,
        embedding: ScriptedEmbedding? = nil, in stack: WriterStorageStack
    ) throws -> WriterDocument {
        let document = try stack.library.createDocument(in: stack.library.inboxGroupID, title: title)
        if let summaryVector, let embedding {
            embedding.exact[SQLiteDocumentIndex.summary(of: document)] = summaryVector
        }
        try stack.documentIndex.index(document, body: body)
        return document
    }
}
