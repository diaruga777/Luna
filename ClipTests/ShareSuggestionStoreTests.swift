//
//  ShareSuggestionStoreTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class ShareSuggestionStoreTests: XCTestCase {

    private var store: ShareSuggestionStore!
    private var scratchDirectory: URL!
    private let alice = (uuid: UUID(), name: "alice")
    private let bob = (uuid: UUID(), name: "bob")

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareSuggestionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        store = ShareSuggestionStore(containerURL: scratchDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        super.tearDown()
    }

    private func shareToAlice(_ url: String = "https://www.example.com/a") {
        store.recordManualShare(urlString: url, friendUUID: alice.uuid, friendUsername: alice.name)
    }

    func testBaseURLStripsSchemeAndWWW() {
        XCTAssertEqual(ShareSuggestionStore.baseURL(of: "https://www.Example.com/x?q=1"), "example.com")
        XCTAssertEqual(ShareSuggestionStore.baseURL(of: "http://news.site.org/y"), "news.site.org")
        XCTAssertNil(ShareSuggestionStore.baseURL(of: "not a url"))
    }

    func testSingleShareDoesNotSuggest() {
        shareToAlice()
        _ = store.handleNewSave(urlString: "https://example.com/new")
        XCTAssertNil(store.pendingSuggestion())
    }

    func testTwoConsecutiveSharesArmSuggestion() {
        shareToAlice("https://example.com/1")
        shareToAlice("https://example.com/2")
        _ = store.handleNewSave(urlString: "https://example.com/3")
        let pending = store.pendingSuggestion()
        XCTAssertEqual(pending?.friendUsername, "alice")
        XCTAssertEqual(pending?.urlString, "https://example.com/3")
    }

    func testSwitchingFriendResetsStreak() {
        shareToAlice("https://example.com/1")
        store.recordManualShare(
            urlString: "https://example.com/2", friendUUID: bob.uuid, friendUsername: bob.name)
        _ = store.handleNewSave(urlString: "https://example.com/3")
        XCTAssertNil(store.pendingSuggestion())
    }

    func testDifferentHostsAreIndependent() {
        shareToAlice("https://example.com/1")
        shareToAlice("https://example.com/2")
        _ = store.handleNewSave(urlString: "https://other.com/x")
        XCTAssertNil(store.pendingSuggestion())
    }

    func testDontShareSuppressesUntilManualShare() {
        shareToAlice("https://example.com/1")
        shareToAlice("https://example.com/2")
        _ = store.handleNewSave(urlString: "https://example.com/3")
        XCTAssertNotNil(store.pendingSuggestion())

        store.applyChoice(.dontShare)
        XCTAssertNil(store.pendingSuggestion())

        // Suppressed: further saves don't suggest.
        _ = store.handleNewSave(urlString: "https://example.com/4")
        XCTAssertNil(store.pendingSuggestion())

        // A manual share re-enables suggestions.
        shareToAlice("https://example.com/5")
        _ = store.handleNewSave(urlString: "https://example.com/6")
        XCTAssertEqual(store.pendingSuggestion()?.friendUsername, "alice")
    }

    func testAlwaysShareAutoSharesAndStopsSuggesting() {
        shareToAlice("https://example.com/1")
        shareToAlice("https://example.com/2")
        _ = store.handleNewSave(urlString: "https://example.com/3")
        store.applyChoice(.alwaysShare)

        let targets = store.handleNewSave(urlString: "https://example.com/4")
        XCTAssertEqual(targets.map(\.uuid), [alice.uuid])
        XCTAssertNil(store.pendingSuggestion()) // always-share friends aren't suggested

        XCTAssertEqual(store.alwaysSharedBaseURLs(friendUUID: alice.uuid), ["example.com"])
    }

    func testShareOnceConsumesPendingAndReturnsIt() {
        shareToAlice("https://example.com/1")
        shareToAlice("https://example.com/2")
        _ = store.handleNewSave(urlString: "https://example.com/3")

        let consumed = store.applyChoice(.shareOnce)
        XCTAssertEqual(consumed?.urlString, "https://example.com/3")
        XCTAssertNil(store.pendingSuggestion())
    }

    func testRemoveAlwaysShareStopsAutomation() {
        shareToAlice("https://example.com/1")
        shareToAlice("https://example.com/2")
        _ = store.handleNewSave(urlString: "https://example.com/3")
        store.applyChoice(.alwaysShare)

        store.removeAlwaysShare(baseURL: "example.com", friendUUID: alice.uuid)
        XCTAssertTrue(store.handleNewSave(urlString: "https://example.com/4").isEmpty)
        XCTAssertTrue(store.alwaysSharedBaseURLs(friendUUID: alice.uuid).isEmpty)
    }

    func testWipeClearsEverythingForFriend() {
        shareToAlice("https://example.com/1")
        shareToAlice("https://example.com/2")
        _ = store.handleNewSave(urlString: "https://example.com/3")
        store.applyChoice(.alwaysShare)
        shareToAlice("https://other.com/1")

        store.wipe(friendUUID: alice.uuid)
        XCTAssertTrue(store.alwaysSharedBaseURLs(friendUUID: alice.uuid).isEmpty)
        XCTAssertTrue(store.handleNewSave(urlString: "https://example.com/5").isEmpty)
        XCTAssertNil(store.pendingSuggestion())
    }

    func testDirectSetAlwaysShareEnablesAndDisables() {
        XCTAssertFalse(store.isAlwaysShared(baseURL: "example.com", friendUUID: alice.uuid))

        store.setAlwaysShare(
            baseURL: "example.com", friendUUID: alice.uuid,
            friendUsername: alice.name, enabled: true)
        XCTAssertTrue(store.isAlwaysShared(baseURL: "example.com", friendUUID: alice.uuid))
        XCTAssertEqual(store.alwaysSharedBaseURLs(friendUUID: alice.uuid), ["example.com"])
        // Now a new save from that site auto-shares to alice.
        XCTAssertEqual(
            store.handleNewSave(urlString: "https://example.com/x").map(\.uuid), [alice.uuid])

        store.setAlwaysShare(
            baseURL: "example.com", friendUUID: alice.uuid,
            friendUsername: alice.name, enabled: false)
        XCTAssertFalse(store.isAlwaysShared(baseURL: "example.com", friendUUID: alice.uuid))
        XCTAssertTrue(store.handleNewSave(urlString: "https://example.com/y").isEmpty)
    }

    func testNewSaveWithoutHistoryClearsStalePending() {
        shareToAlice("https://example.com/1")
        shareToAlice("https://example.com/2")
        _ = store.handleNewSave(urlString: "https://example.com/3")
        XCTAssertNotNil(store.pendingSuggestion())

        _ = store.handleNewSave(urlString: "https://unrelated.org/x")
        XCTAssertNil(store.pendingSuggestion())
    }
}
