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

    func testACaptureLandsOnEverySheetItIsCloseEnoughTo() throws {
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
