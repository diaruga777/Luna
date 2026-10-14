import Foundation
import LunaModels
import XCTest
@testable import LunaStorage

final class SavedLibrarySearchTests: XCTestCase {
    private var directory: URL!
    private var store: SavesStore!
    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = SavesStore(containerURL: directory)
    }
    override func tearDown() { store = nil; try? FileManager.default.removeItem(at: directory) }

    private func save(_ title: String, body: String) -> SavedItem {
        let item = store.add(urlString: "https://example.com/\(UUID().uuidString)")
        return store.saveContent(ArticleContent(title: title, blocks: [
            .init(kind: .paragraph, text: body, links: []),
            .init(kind: .caption, text: "Extracted captions mention quokka habitats", links: []),
        ]), for: item)
    }

    func testImmediateFullTextCaptionPrefixAndSafeQuerySyntax() throws {
        let saved = save("An unrelated headline", body: "An unusual narwhal lives here.")
        let index = SavedLibrarySearchIndex(store: store)
        XCTAssertEqual(try index.matches("narw"), [saved.id])
        XCTAssertEqual(try index.matches("quokka"), [saved.id])
        XCTAssertEqual(try index.matches("\" OR * : ()"), [])
        XCTAssertEqual(try index.matches("🌙"), [])
    }

    func testDurabilitySiblingUpdatesSameFilenameAndDeletion() throws {
        let saved = save("First headline", body: "Platypus conservation")
        let sibling = SavesStore(containerURL: directory)
        let index = SavedLibrarySearchIndex(store: sibling)
        XCTAssertEqual(try index.matches("platypus"), [saved.id])
        let replaced = store.saveContent(ArticleContent(title: "Second headline", blocks: [
            .init(kind: .paragraph, text: "Wombat migration", links: []),
        ]), for: saved)
        XCTAssertEqual(replaced.contentFileName, saved.contentFileName)
        XCTAssertEqual(try index.matches("platypus"), [])
        XCTAssertEqual(try index.matches("wombat"), [saved.id])
        XCTAssertEqual(try index.matches("first"), [])
        store.delete(replaced)
        XCTAssertEqual(try index.matches("wombat"), [])
    }

    func testSearchReadsPrebuiltIndexAfterContentFileIsGone() throws {
        let saved = save("Document", body: "A searchable axolotl.")
        try FileManager.default.removeItem(at: store.articlesDirectory.appendingPathComponent(saved.contentFileName!))
        XCTAssertEqual(try SavedLibrarySearchIndex(store: store).matches("axolotl"), [saved.id])
    }

    func testSemanticOnlyRetrievalPrebuiltVectorsAndStaleGenerationExclusion() throws {
        let saved = save("City report", body: "Housing affordability affects residents.")
        var calls = 0
        let embedding: (String) -> [Double]? = { text in
            calls += 1
            return text.contains("Housing") || text.contains("shelter") ? [1, 0] : [0, 1]
        }
        let index = SavedLibrarySearchIndex(store: store, embedding: embedding)
        index.runSavesSweep()
        let builtCalls = calls
        XCTAssertEqual(try index.matches("shelter costs"), [saved.id], "semantic candidates need no exact words")
        XCTAssertEqual(calls, builtCalls + 1, "only the query is embedded while searching")
        let reopened = SavedLibrarySearchIndex(store: SavesStore(containerURL: directory), embedding: embedding)
        reopened.runSavesSweep()
        XCTAssertEqual(calls, builtCalls + 1, "opening an unchanged index must reuse stored vectors")
        XCTAssertEqual(try reopened.matches("shelter costs"), [saved.id])
        _ = store.saveContent(ArticleContent(title: "New report", blocks: [
            .init(kind: .paragraph, text: "Unrelated wildlife", links: []),
        ]), for: saved)
        XCTAssertEqual(try index.matches("shelter costs"), [], "old vectors must stop matching before rebuilding")
        store.delete(store.item(withID: saved.id)!)
        XCTAssertEqual(try reopened.matches("shelter costs"), [])
    }

    func testLegacyBackfillAndProgressChangesDoNotReembed() throws {
        let saved = save("Legacy", body: "Echidna country")
        try store.keyboardWrite { db in
            try db.run("UPDATE library_documents SET body='', needs_backfill=1 WHERE save_id=?") {
                try $0.bind(1, uuid: saved.id)
            }
        }
        var calls = 0
        let index = SavedLibrarySearchIndex(store: store, embedding: { _ in calls += 1; return [1, 0] })
        index.runSavesSweep()
        XCTAssertEqual(try index.matches("echidna"), [saved.id])
        let before = calls
        store.markReadState(.opened, for: saved.id)
        index.runSavesSweep()
        XCTAssertEqual(calls, before)
    }

    func testSentenceChunkingIsBoundedAndDoesNotLoseLongSentences() {
        let words = (0..<700).map { "word\($0)" }
        let chunks = SavedLibrarySearchIndex.chunks("Section heading\n" + words.joined(separator: " ") + ".")
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(chunks.allSatisfy { $0.split(whereSeparator: \.isWhitespace).count <= 120 })
        let restored = chunks.joined(separator: " ")
        XCTAssertTrue(words.allSatisfy { restored.contains($0) })
    }

    func testLargePrebuiltLexicalIndexLatency() throws {
        try store.keyboardWrite { db in
            for ordinal in 0..<2500 {
                let id = UUID()
                try db.run("""
                    INSERT INTO saves(id, seq, url_string, title, date_added, state, read_state)
                    VALUES(?, ?, ?, ?, 0, 'ready', 'unopened')
                    """) {
                    try $0.bind(1, uuid: id); try $0.bind(2, ordinal)
                    try $0.bind(3, "https://example.com/\(ordinal)"); try $0.bind(4, "Article \(ordinal)")
                }
                try SavedLibrarySearchSchema.setBody("Full text about wildlife token\(ordinal)", id: id, in: db)
            }
        }
        let index = SavedLibrarySearchIndex(store: store)
        var durations: [Double] = []
        for ordinal in 100..<200 {
            let start = CFAbsoluteTimeGetCurrent()
            XCTAssertEqual(try index.matches("token\(ordinal)" ).count, 11)
            durations.append(CFAbsoluteTimeGetCurrent() - start)
        }
        durations.sort()
        print("Library FTS 2500 saves p95: \(durations[95] * 1000) ms")
        XCTAssertLessThan(durations[95], 0.05)
    }

    func testLargePrebuiltVectorIndexLatency() throws {
        let values: [Float] = [1] + Array(repeating: 0, count: 767)
        let blob = values.withUnsafeBufferPointer { Data(buffer: $0) }
        try store.keyboardWrite { db in
            for ordinal in 0..<2500 {
                let id = UUID()
                try db.run("""
                    INSERT INTO saves(id, seq, url_string, title, date_added, state, read_state)
                    VALUES(?, ?, ?, 'Report', 0, 'ready', 'unopened')
                    """) {
                    try $0.bind(1, uuid: id); try $0.bind(2, ordinal)
                    try $0.bind(3, "https://example.com/\(ordinal)")
                }
                try db.run("UPDATE library_documents SET needs_backfill=0, embedded_generation=generation, model='test-v1' WHERE save_id=?") {
                    try $0.bind(1, uuid: id)
                }
                for chunk in 0..<2 {
                    try db.run("INSERT INTO library_vectors VALUES(?, ?, 768, ?)") {
                        try $0.bind(1, uuid: id); try $0.bind(2, chunk); try $0.bind(3, blob: blob)
                    }
                }
            }
        }
        let index = SavedLibrarySearchIndex(store: store, embedding: { _ in values.map(Double.init) })
        index.runSavesSweep()
        var durations: [Double] = []
        for _ in 0..<20 {
            let start = CFAbsoluteTimeGetCurrent()
            XCTAssertEqual(try index.matches("meaning without exact words").count, 2500)
            durations.append(CFAbsoluteTimeGetCurrent() - start)
        }
        durations.sort()
        print("Library vector search 5000 prebuilt chunks p95: \(durations[19] * 1000) ms")
        XCTAssertLessThan(durations[19], 0.1)
    }
}
