//
//  SentenceEmbeddingTests.swift
//  LunaTests
//

import Foundation
import XCTest
@testable import LunaWriterStorage
import NaturalLanguage

/// `NLSentenceEmbedding` must not touch `NLEmbedding` at construction —
/// `WriterStorageStack.makeDefault` builds one on the main thread at launch,
/// before the window exists.
final class SentenceEmbeddingTests: XCTestCase {

    func testConstructionDoesNotLoadTheModel() {
        var loadCount = 0
        _ = NLSentenceEmbedding(language: .english) { _ in
            loadCount += 1
            return nil
        }

        XCTAssertEqual(loadCount, 0)
    }

    func testFirstVectorRequestLoadsTheModelExactlyOnce() {
        var loadCount = 0
        let embedding = NLSentenceEmbedding(language: .english) { _ in
            loadCount += 1
            return nil
        }

        _ = embedding.vector(for: "a sentence")
        _ = embedding.vector(for: "another sentence")
        _ = embedding.dimensions
        _ = embedding.modelVersion

        XCTAssertEqual(loadCount, 1)
    }

    func testDimensionsAloneAlsoTriggersAndCachesTheLoad() {
        var loadCount = 0
        let embedding = NLSentenceEmbedding(language: .english) { _ in
            loadCount += 1
            return nil
        }

        _ = embedding.dimensions
        _ = embedding.dimensions

        XCTAssertEqual(loadCount, 1)
    }

    func testAnUnavailableModelReportsNoEmbeddingRatherThanFailing() {
        let embedding = NLSentenceEmbedding(language: .english) { _ in nil }

        XCTAssertEqual(embedding.dimensions, 0)
        XCTAssertNil(embedding.vector(for: "a sentence"))
    }

    func testBuildingTheDefaultStorageStackDoesNotLoadTheModel() throws {
        var loadCount = 0
        let embedding = NLSentenceEmbedding(language: .english) { _ in
            loadCount += 1
            return nil
        }
        let root = try makeWriterTemporaryDirectory()
        let suiteName = "luna.writer.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        _ = try WriterStorageStack(
            databaseURL: root.appendingPathComponent("writer.sqlite"),
            libraryRoot: root.appendingPathComponent("Library", isDirectory: true),
            embedding: embedding, defaults: defaults)

        XCTAssertEqual(loadCount, 0)
    }
}
