import Foundation
import XCTest
@testable import LunaVaultSearch
import LunaVaultEmbeddings
import LunaVaultModels

final class LunaVaultSearchTests: XCTestCase {
    private func makeIndex() throws -> (VaultSearchIndex, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("vault-search-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (try VaultSearchIndex(databaseURL: directory.appendingPathComponent("index.sqlite")), directory)
    }
    private func document(_ number: Int, filename: String, body: String, vector: [Float]? = nil) -> VaultIndexedDocument {
        let id = VaultObjectID(rawValue: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number))!)
        let revision = UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", number))!
        let date = Date(timeIntervalSinceReferenceDate: TimeInterval(number))
        return VaultIndexedDocument(id: id, revision: revision, filename: filename, bodyText: body, ocrText: "OCR \(body)", transcriptText: "Transcript \(body)", createdAt: date, updatedAt: date, accessedAt: date, embedding: vector.map { VaultEmbedding(values: $0, modelVersion: "test-v1") })
    }

    func testFTSIndexesFilenameBodyOCRTranscriptAndPersistsAcrossReopen() throws {
        let (index, directory) = try makeIndex()
        try index.upsert(document(1, filename: "meeting-notes.txt", body: "quarterly planning"))
        XCTAssertEqual(try index.search("planning").first?.objectID.rawValue.uuidString, "00000000-0000-0000-0000-000000000001")
        XCTAssertEqual(try index.search("OCR quarterly").count, 1)
        XCTAssertEqual(try index.search("Transcript quarterly").count, 1)
        let reopened = try VaultSearchIndex(databaseURL: directory.appendingPathComponent("index.sqlite"))
        XCTAssertEqual(try reopened.search("meeting-notes").count, 1)
        XCTAssertEqual(try reopened.integrityCheck(), "ok")
        XCTAssertTrue(try reopened.foreignKeysEnabled())
    }

    func testModelVersionAndDimensionAreIsolated() throws {
        let (index, _) = try makeIndex()
        try index.upsert(document(1, filename: "a", body: "one", vector: [1, 0]))
        try index.upsert(document(2, filename: "b", body: "two", vector: [0, 1]))
        XCTAssertEqual(try index.cosineSearch(VaultEmbedding(values: [1, 0], modelVersion: "test-v1")).first?.0.rawValue.uuidString, "00000000-0000-0000-0000-000000000001")
        XCTAssertTrue(try index.cosineSearch(VaultEmbedding(values: [1, 0], modelVersion: "other-model")).isEmpty)
        XCTAssertThrowsError(try index.cosineSearch(VaultEmbedding(values: [1, 0, 0], modelVersion: "test-v1"))) { XCTAssertEqual($0 as? VaultSearchError, .dimensionMismatch(expected: 3, actual: 2)) }
    }

    func testHybridSearchHasStableTieBreakAndMetadata() throws {
        let (index, _) = try makeIndex()
        try index.upsert(document(1, filename: "alpha.txt", body: "shared phrase", vector: [1, 0]))
        try index.upsert(document(2, filename: "beta.txt", body: "shared phrase", vector: [1, 0]))
        let results = try index.search("shared phrase", embedding: VaultEmbedding(values: [1, 0], modelVersion: "test-v1"), limit: 10)
        XCTAssertEqual(results.map { $0.filename }, ["alpha.txt", "beta.txt"])
        XCTAssertEqual(results.first?.source, .device)
        XCTAssertFalse(results.first?.snippet.isEmpty ?? true)
        XCTAssertTrue(results.first?.matchedFields.contains("text") ?? false)
    }

    func testAutomaticGroupsAreStableAndFrozenLabelsDoNotChange() throws {
        let (index, _) = try makeIndex()
        try index.upsert(document(1, filename: "cats.jpg", body: "cats", vector: [1, 0]))
        try index.upsert(document(2, filename: "kitten.jpg", body: "cats", vector: [0.99, 0.01]))
        try index.upsert(document(3, filename: "ocean.jpg", body: "ocean", vector: [0, 1]))
        let first = try index.evolveAutomaticGroups(modelVersion: "test-v1", threshold: 0.8)
        XCTAssertEqual(first.count, 2)
        let cats = try XCTUnwrap(first.first { $0.memberIDs.count == 2 })
        try index.renameGroup(cats.id, label: "Pinned", frozen: true)
        try index.evolveAutomaticGroups(modelVersion: "test-v1", threshold: 0.8)
        let pinned = try XCTUnwrap(try index.groups().first { $0.id == cats.id })
        XCTAssertEqual(pinned.label, "Pinned")
        XCTAssertEqual(pinned.memberIDs.count, 2)
    }

    func testQueryGroupSnapshotAndLiveModes() throws {
        let (index, _) = try makeIndex()
        try index.upsert(document(1, filename: "one.txt", body: "project"))
        let snapshot = try index.createQueryGroup(query: "project", members: [try XCTUnwrap(try index.allDocuments().first?.id)])
        XCTAssertFalse(try XCTUnwrap(index.queryGroup(snapshot.id)).map(\.live) ?? true)
        let live = try index.createQueryGroup(query: "project", members: [], live: true)
        try index.upsert(document(2, filename: "two.txt", body: "project"))
        XCTAssertEqual(try XCTUnwrap(index.queryGroup(live.id)).map(\.memberIDs.count), 2)
        XCTAssertEqual(try XCTUnwrap(index.queryGroup(snapshot.id)).map(\.memberIDs.count), 1)
    }

    func testTombstoneRemovesSearchAndStaleRevisionCannotResurrect() throws {
        let (index, _) = try makeIndex()
        let doc = document(1, filename: "gone.txt", body: "secret")
        try index.upsert(doc)
        try index.delete(doc.id, revision: UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff")!)
        XCTAssertTrue(try index.search("secret").isEmpty)
        try index.upsert(doc)
        XCTAssertTrue(try index.search("secret").isEmpty)
        XCTAssertTrue(try XCTUnwrap(try index.document(doc.id)).isTombstone)
    }

    func testEmptyQueryFailsClosedAndRebuildIsIdempotent() throws {
        let (index, _) = try makeIndex()
        XCTAssertThrowsError(try index.search("   "))
        try index.upsert(document(1, filename: "idempotent.txt", body: "word"))
        try index.rebuild(modelVersion: "test-v1")
        try index.rebuild(modelVersion: "test-v1")
        XCTAssertEqual(try index.search("word").count, 1)
    }
}
