//
//  RecentFriendRecipientsStoreTests.swift
//  LunaTests
//

import LunaSocial
import XCTest

final class RecentFriendRecipientsStoreTests: XCTestCase {

    private var scratchDirectory: URL!
    private var store: RecentFriendRecipientsStore!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentFriendRecipientsStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        store = RecentFriendRecipientsStore(containerURL: scratchDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        store = nil
        scratchDirectory = nil
        super.tearDown()
    }

    func testRecordsNewestRecipientsFirst() {
        store.recordSent(to: ["first@example.com"], now: Date(timeIntervalSince1970: 10))
        store.recordSent(to: ["second@example.com"], now: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(store.items().map(\.email), ["second@example.com", "first@example.com"])
    }

    func testReSendingRecipientMovesItToTopAndLimitApplies() {
        store.recordSent(to: ["a@example.com"], now: Date(timeIntervalSince1970: 10))
        store.recordSent(to: ["b@example.com"], now: Date(timeIntervalSince1970: 20))
        store.recordSent(to: ["a@example.com"], now: Date(timeIntervalSince1970: 30))

        XCTAssertEqual(store.items(limit: 1).map(\.email), ["a@example.com"])
        XCTAssertEqual(store.items().map(\.email), ["a@example.com", "b@example.com"])
    }

    func testIgnoresInvalidEmails() {
        store.recordSent(to: ["not-an-email", "valid@example.com"])

        XCTAssertEqual(store.items().map(\.email), ["valid@example.com"])
    }
}
