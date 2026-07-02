//
//  SemanticIndexStoreTests.swift
//  LunaTests
//

import LunaSemantic
import XCTest
@testable import Luna

final class SemanticIndexStoreTests: XCTestCase {

    private var scratch: URL!
    private var store: SemanticIndexStore!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemanticIndex-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = SemanticIndexStore(containerURL: scratch)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    func testCosine() {
        XCTAssertEqual(SemanticIndexStore.cosine([1, 0], [1, 0]), 1, accuracy: 0.0001)
        XCTAssertEqual(SemanticIndexStore.cosine([1, 0], [0, 1]), 0, accuracy: 0.0001)
        XCTAssertEqual(SemanticIndexStore.cosine([1, 1], [-1, -1]), -1, accuracy: 0.0001)
        XCTAssertEqual(SemanticIndexStore.cosine([], []), 0)
        XCTAssertEqual(SemanticIndexStore.cosine([1, 2], [1]), 0, "length mismatch → 0")
    }

    func testMaxChunkSimilarityUsesClosestPair() {
        // One chunk pair is identical even though others are orthogonal.
        let a: [[Float]] = [[1, 0, 0], [0, 1, 0]]
        let b: [[Float]] = [[0, 0, 1], [1, 0, 0]]
        XCTAssertEqual(SemanticIndexStore.maxChunkSimilarity(a, b), 1, accuracy: 0.0001)
    }

    func testNearestItemsRanksBySimilarity() {
        let close = UUID(), far = UUID()
        store.setVectors([[1, 0, 0]], forItemID: close)
        store.setVectors([[0, 1, 0]], forItemID: far)
        let results = store.nearestItems(
            toVectors: [[0.98, 0.2, 0]], threshold: 0.5, excluding: [], limit: 10)
        XCTAssertEqual(results.first?.itemID, close)
        XCTAssertFalse(results.contains { $0.itemID == far }, "orthogonal item is below threshold")
    }

    func testNearestItemsHonorsExclusions() {
        let a = UUID()
        store.setVectors([[1, 0]], forItemID: a)
        let results = store.nearestItems(
            toVectors: [[1, 0]], threshold: 0.5, excluding: [a], limit: 10)
        XCTAssertTrue(results.isEmpty)
    }

    func testItemIDsNeedingVectorsAmongAll() {
        let indexed = UUID(), missing = UUID()
        store.setVectors([[1, 0]], forItemID: indexed)
        let needed = store.itemIDsNeedingVectors(amongAll: [indexed, missing], limit: 10)
        XCTAssertEqual(needed, [missing])
    }
}

final class SemanticSensitivityTests: XCTestCase {

    func testThresholdIsMonotonicAndBounded() {
        let off = SemanticSharingSettings.threshold(forSensitivity: 0)
        let mid = SemanticSharingSettings.threshold(forSensitivity: 0.5)
        let often = SemanticSharingSettings.threshold(forSensitivity: 1)
        // Higher sensitivity → lower threshold → more suggestions.
        XCTAssertGreaterThan(off, mid)
        XCTAssertGreaterThan(mid, often)
        XCTAssertEqual(off, SemanticSharingSettings.strictestThreshold, accuracy: 0.0001)
        XCTAssertEqual(often, SemanticSharingSettings.loosestThreshold, accuracy: 0.0001)
    }

    func testThresholdClampsOutOfRange() {
        XCTAssertEqual(SemanticSharingSettings.threshold(forSensitivity: -5),
                       SemanticSharingSettings.strictestThreshold, accuracy: 0.0001)
        XCTAssertEqual(SemanticSharingSettings.threshold(forSensitivity: 5),
                       SemanticSharingSettings.loosestThreshold, accuracy: 0.0001)
    }
}
