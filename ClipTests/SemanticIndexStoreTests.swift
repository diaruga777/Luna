//
//  SemanticIndexStoreTests.swift
//  ClipTests
//

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

    func testBestMatchFindsCloseFriendAboveThreshold() {
        let alice = UUID(), bob = UUID()
        let shareToAlice = UUID(), shareToBob = UUID(), newItem = UUID()
        // Alice got an item very similar to the new one; Bob got an orthogonal one.
        store.setVector([1, 0, 0], forItemID: shareToAlice)
        store.setVector([0, 1, 0], forItemID: shareToBob)
        store.setVector([0.98, 0.2, 0], forItemID: newItem)
        store.recordShare(itemID: shareToAlice, personUUID: alice, username: "alice")
        store.recordShare(itemID: shareToBob, personUUID: bob, username: "bob")

        let match = store.bestMatch(forItemID: newItem)
        XCTAssertEqual(match?.uuid, alice)
        XCTAssertEqual(match?.username, "alice")
        XCTAssertGreaterThanOrEqual(match?.score ?? 0, SemanticIndexStore.similarityThreshold)
    }

    func testBestMatchNilWhenNothingClose() {
        let bob = UUID(), shareToBob = UUID(), newItem = UUID()
        store.setVector([0, 1, 0], forItemID: shareToBob)
        store.setVector([1, 0, 0], forItemID: newItem) // orthogonal → cosine 0
        store.recordShare(itemID: shareToBob, personUUID: bob, username: "bob")
        XCTAssertNil(store.bestMatch(forItemID: newItem))
    }

    func testBestMatchExcludesAlreadySharedItem() {
        let alice = UUID(), item = UUID()
        store.setVector([1, 0, 0], forItemID: item)
        store.recordShare(itemID: item, personUUID: alice, username: "alice")
        // The item itself was shared to alice — don't suggest re-sharing it.
        XCTAssertNil(store.bestMatch(forItemID: item))
    }

    func testCheckQueueEnqueueDequeue() {
        let a = UUID(), b = UUID()
        store.enqueueSemanticCheck(itemID: a)
        store.enqueueSemanticCheck(itemID: a) // dedup
        store.enqueueSemanticCheck(itemID: b)
        XCTAssertEqual(Set(store.dequeueChecks()), [a, b])
        XCTAssertTrue(store.dequeueChecks().isEmpty)
    }

    func testItemIDsNeedingVectorsCoversQueueAndShares() {
        let queued = UUID(), shared = UUID(), indexed = UUID()
        let person = UUID()
        store.enqueueSemanticCheck(itemID: queued)
        store.recordShare(itemID: shared, personUUID: person, username: "p")
        store.setVector([1, 0], forItemID: indexed)
        store.recordShare(itemID: indexed, personUUID: person, username: "p")
        let needed = Set(store.itemIDsNeedingVectors(limit: 10))
        XCTAssertTrue(needed.contains(queued))
        XCTAssertTrue(needed.contains(shared))
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
