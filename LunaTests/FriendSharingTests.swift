//
//  FriendSharingTests.swift
//  LunaTests
//
//  Merges RecentFriendRecipientsStoreTests, PendingRequestsStoreTests, and
//  ReaderCardSenderTests: friend-sharing's recipient bookkeeping, incoming
//  pending requests, and the reader card's sender-name resolution.
//

import LunaModels
import LunaSocial
import XCTest
@testable import Luna

final class FriendSharingTests: XCTestCase {

    // MARK: - Shared fixtures
    //
    // RecentFriendRecipientsStoreTests and PendingRequestsStoreTests each
    // scratch their own store in their own temp directory; both are named
    // distinctly ("Recent…"/"pending…") since the two stores are different
    // types and neither test group touches the other's fixture.

    private var recentRecipientsScratchDirectory: URL!
    private var recentRecipientsStore: RecentFriendRecipientsStore!

    private var pendingRequestsScratch: URL!
    private var pendingRequestsStore: PendingRequestsStore!

    override func setUp() {
        super.setUp()
        recentRecipientsScratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecentFriendRecipientsStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: recentRecipientsScratchDirectory, withIntermediateDirectories: true)
        recentRecipientsStore = RecentFriendRecipientsStore(containerURL: recentRecipientsScratchDirectory)

        pendingRequestsScratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingReq-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: pendingRequestsScratch, withIntermediateDirectories: true)
        pendingRequestsStore = PendingRequestsStore(containerURL: pendingRequestsScratch)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: recentRecipientsScratchDirectory)
        recentRecipientsStore = nil
        recentRecipientsScratchDirectory = nil

        try? FileManager.default.removeItem(at: pendingRequestsScratch)
        pendingRequestsStore = nil
        pendingRequestsScratch = nil
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

    // MARK: - PendingRequestsStoreTests

    private func request(url: String = "https://ex.com/a") -> PendingRequest {
        PendingRequest(senderEmail: "bob@example.com", senderName: "Bob", urlString: url,
                       title: "A", kind: "article", messageID: "1")
    }

    func testLoadsAndRemovesLegacyRequests() throws {
        let item = request()
        try JSONEncoder().encode([item]).write(
            to: pendingRequestsScratch.appendingPathComponent("pendingRequests.json"), options: .atomic)

        XCTAssertEqual(pendingRequestsStore.items(), [item])
        XCTAssertEqual(pendingRequestsStore.count, 1)
        pendingRequestsStore.remove(id: item.id)
        XCTAssertEqual(pendingRequestsStore.count, 0)
    }

    func testLegacyRequestsAreSortedNewestFirst() throws {
        let older = PendingRequest(
            senderEmail: "bob@example.com", senderName: "Bob",
            urlString: "https://ex.com/old", title: "Old", kind: "article",
            messageID: "1", date: Date(timeIntervalSince1970: 1))
        let newer = PendingRequest(
            senderEmail: "alice@example.com", senderName: "Alice",
            urlString: "https://ex.com/new", title: "New", kind: "article",
            messageID: "2", date: Date(timeIntervalSince1970: 2))
        try JSONEncoder().encode([older, newer]).write(
            to: pendingRequestsScratch.appendingPathComponent("pendingRequests.json"), options: .atomic)

        XCTAssertEqual(pendingRequestsStore.items().map(\.id), [newer.id, older.id])
    }

    func testDisplaySenderFallsBackToLocalPart() {
        let req = PendingRequest(senderEmail: "carol@example.com", senderName: nil,
                                 urlString: "https://x", title: nil, kind: "link", messageID: nil)
        XCTAssertEqual(req.displaySender, "carol")
    }

    // MARK: - ReaderCardSenderTests

    func testIncomingEmailUsesCurrentContactName() {
        var item = ReadingListItem(urlString: "https://example.com/article")
        item.captureSource = .email
        item.channelName = "Original Name"
        item.incomingSenderEmail = "sender@example.com"

        XCTAssertEqual(
            ArticleCardPresenter.resolvedSenderName(for: item) { email in
                email == "sender@example.com" ? "Renamed Contact" : nil
            },
            "Renamed Contact")
    }

    func testIncomingEmailFallsBackToCapturedName() {
        var item = ReadingListItem(urlString: "lunamail://message")
        item.captureSource = .email
        item.channelName = "Newsletter Name"
        item.incomingSenderEmail = "news@example.com"

        XCTAssertEqual(
            ArticleCardPresenter.resolvedSenderName(for: item) { _ in nil },
            "Newsletter Name")
    }

    func testNonEmailItemHasNoSenderLabel() {
        var item = ReadingListItem(urlString: "https://example.com/article")
        item.captureSource = .shareSheet
        item.channelName = "Publisher"

        XCTAssertNil(ArticleCardPresenter.resolvedSenderName(for: item) { _ in "Contact" })
    }
}
