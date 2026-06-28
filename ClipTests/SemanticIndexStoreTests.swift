//
//  SemanticIndexStoreTests.swift
//  ClipTests
//

import ClipSocial
import XCTest
@testable import Clip

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

    /// A fixed threshold for deterministic assertions, independent of the
    /// user-facing sensitivity slider.
    private let testThreshold: Float = 0.55

    /// bestMatch with throwaway out-params, for terse assertions.
    private func match(_ itemID: UUID) -> SemanticIndexStore.Match? {
        var s: Float = 0; var u: String?; var i: UUID?
        return store.bestMatch(forItemID: itemID, threshold: testThreshold,
                               bestScore: &s, bestUsername: &u, bestItemID: &i)
    }

    func testMaxChunkSimilarityUsesClosestPair() {
        // One chunk pair is identical even though others are orthogonal.
        let a: [[Float]] = [[1, 0, 0], [0, 1, 0]]
        let b: [[Float]] = [[0, 0, 1], [1, 0, 0]]
        XCTAssertEqual(SemanticIndexStore.maxChunkSimilarity(a, b), 1, accuracy: 0.0001)
    }

    func testBestMatchFindsCloseFriendAboveThreshold() {
        let alice = UUID(), bob = UUID()
        let shareToAlice = UUID(), shareToBob = UUID(), newItem = UUID()
        store.setVectors([[1, 0, 0]], forItemID: shareToAlice)
        store.setVectors([[0, 1, 0]], forItemID: shareToBob)
        store.setVectors([[0.98, 0.2, 0]], forItemID: newItem)
        store.recordShare(itemID: shareToAlice, personUUID: alice, username: "alice")
        store.recordShare(itemID: shareToBob, personUUID: bob, username: "bob")

        let m = match(newItem)
        XCTAssertEqual(m?.uuid, alice)
        XCTAssertEqual(m?.matchedItemID, shareToAlice)
        XCTAssertGreaterThanOrEqual(m?.score ?? 0, testThreshold)
    }

    func testBestMatchNilWhenNothingClose() {
        let bob = UUID(), shareToBob = UUID(), newItem = UUID()
        store.setVectors([[0, 1, 0]], forItemID: shareToBob)
        store.setVectors([[1, 0, 0]], forItemID: newItem) // orthogonal → 0
        store.recordShare(itemID: shareToBob, personUUID: bob, username: "bob")
        XCTAssertNil(match(newItem))
    }

    func testBestMatchExcludesAlreadySharedItem() {
        let alice = UUID(), item = UUID()
        store.setVectors([[1, 0, 0]], forItemID: item)
        store.recordShare(itemID: item, personUUID: alice, username: "alice")
        XCTAssertNil(match(item), "don't suggest re-sharing the same item")
    }

    func testBestScoreReportedEvenBelowThreshold() {
        let bob = UUID(), shareToBob = UUID(), newItem = UUID()
        store.setVectors([[1, 0, 0]], forItemID: shareToBob)
        store.setVectors([[0.5, 0.87, 0]], forItemID: newItem) // ~0.5 cosine, below 0.55
        store.recordShare(itemID: shareToBob, personUUID: bob, username: "bob")
        var s: Float = 0; var u: String?; var i: UUID?
        _ = store.bestMatch(forItemID: newItem, threshold: testThreshold,
                            bestScore: &s, bestUsername: &u, bestItemID: &i)
        XCTAssertEqual(u, "bob")
        XCTAssertGreaterThan(s, 0)
        XCTAssertLessThan(s, testThreshold)
    }

    func testItemIDsNeedingVectorsCoversSharedItems() {
        let shared = UUID(), indexed = UUID()
        let person = UUID()
        store.recordShare(itemID: shared, personUUID: person, username: "p")
        store.setVectors([[1, 0]], forItemID: indexed)
        store.recordShare(itemID: indexed, personUUID: person, username: "p")
        let needed = Set(store.itemIDsNeedingVectors(limit: 10))
        XCTAssertTrue(needed.contains(shared), "shared item without a vector")
        XCTAssertFalse(needed.contains(indexed), "already has a vector")
    }
}

final class SuggestionKeyTests: XCTestCase {

    func testYouTubeKeysByChannel() {
        let key = ShareSuggestionStore.suggestionKey(
            urlString: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", channelName: "MKBHD")
        XCTAssertEqual(key, "youtube-channel:mkbhd")
    }

    func testYouTubeWithoutChannelHasNoKey() {
        XCTAssertNil(ShareSuggestionStore.suggestionKey(
            urlString: "https://youtu.be/dQw4w9WgXcQ", channelName: nil))
        XCTAssertNil(ShareSuggestionStore.suggestionKey(
            urlString: "https://youtu.be/dQw4w9WgXcQ", channelName: "  "))
    }

    func testNonYouTubeKeysByHost() {
        XCTAssertEqual(
            ShareSuggestionStore.suggestionKey(
                urlString: "https://www.theverge.com/x", channelName: nil),
            "theverge.com")
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
