//
//  FriendSharingTests.swift
//  LunaTests
//
//  Merges RecentFriendRecipientsStoreTests and
//  ReaderCardSenderTests: friend-sharing's recipient bookkeeping, incoming
//  pending requests, and the reader card's sender-name resolution.
//

import LunaModels
import LunaSocial
import XCTest
@testable import Luna

final class FriendSharingTests: XCTestCase {

    // MARK: - Shared fixtures

    private var recentRecipientsScratchDirectory: URL!
    private var recentRecipientsStore: RecentFriendRecipientsStore!

    override func setUp() {
        super.setUp()
        recentRecipientsScratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentFriendRecipientsStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: recentRecipientsScratchDirectory, withIntermediateDirectories: true)
        recentRecipientsStore = RecentFriendRecipientsStore(containerURL: recentRecipientsScratchDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: recentRecipientsScratchDirectory)
        recentRecipientsStore = nil
        recentRecipientsScratchDirectory = nil
        super.tearDown()
    }

    // MARK: - RecentFriendRecipientsStoreTests

    func testRecordsNewestRecipientsFirst() {
        recentRecipientsStore.recordSent(to: ["first@example.com"], now: Date(timeIntervalSince1970: 10))
        recentRecipientsStore.recordSent(to: ["second@example.com"], now: Date(timeIntervalSince1970: 20))

        XCTAssertEqual(
            recentRecipientsStore.items().map(\.email), ["second@example.com", "first@example.com"])
    }

    func testReSendingRecipientMovesItToTopAndLimitApplies() {
        recentRecipientsStore.recordSent(to: ["a@example.com"], now: Date(timeIntervalSince1970: 10))
        recentRecipientsStore.recordSent(to: ["b@example.com"], now: Date(timeIntervalSince1970: 20))
        recentRecipientsStore.recordSent(to: ["a@example.com"], now: Date(timeIntervalSince1970: 30))

        XCTAssertEqual(recentRecipientsStore.items(limit: 1).map(\.email), ["a@example.com"])
        XCTAssertEqual(
            recentRecipientsStore.items().map(\.email), ["a@example.com", "b@example.com"])
    }

    func testIgnoresInvalidEmails() {
        recentRecipientsStore.recordSent(to: ["not-an-email", "valid@example.com"])

        XCTAssertEqual(recentRecipientsStore.items().map(\.email), ["valid@example.com"])
    }

    func testRecordingRepairsDuplicateLegacyRowsWithoutTrapping() throws {
        let duplicate = [
            RecentFriendRecipientsStore.Recipient(
                email: "same@example.com", lastSentAt: Date(timeIntervalSince1970: 1)),
            RecentFriendRecipientsStore.Recipient(
                email: "same@example.com", lastSentAt: Date(timeIntervalSince1970: 2)),
        ]
        try JSONEncoder().encode(duplicate).write(
            to: recentRecipientsScratchDirectory.appendingPathComponent("recentFriendRecipients.json"),
            options: .atomic)

        recentRecipientsStore.recordSent(to: ["other@example.com"], now: Date(timeIntervalSince1970: 3))

        XCTAssertEqual(
            recentRecipientsStore.items().map(\.email), ["other@example.com", "same@example.com"])
    }

    // MARK: - ReaderCardSenderTests

    func testIncomingEmailUsesCurrentContactName() {
        var item = SavedItem(urlString: "https://example.com/article")
        item.captureSource = .email
        item.senderName = "Original Name"
        item.incomingSenderEmail = "sender@example.com"

        XCTAssertEqual(
            ArticleCardPresenter.resolvedSenderName(for: item) { email in
                email == "sender@example.com" ? "Renamed Contact" : nil
            },
            "Renamed Contact")
    }

    func testIncomingEmailFallsBackToCapturedName() {
        var item = SavedItem(urlString: "lunamail://message")
        item.captureSource = .email
        item.senderName = "Newsletter Name"
        item.incomingSenderEmail = "news@example.com"

        XCTAssertEqual(
            ArticleCardPresenter.resolvedSenderName(for: item) { _ in nil },
            "Newsletter Name")
    }

    func testNonEmailItemHasNoSenderLabel() {
        var item = SavedItem(urlString: "https://example.com/article")
        item.captureSource = .shareSheet
        item.senderName = "Publisher"

        XCTAssertNil(ArticleCardPresenter.resolvedSenderName(for: item) { _ in "Contact" })
    }
}
