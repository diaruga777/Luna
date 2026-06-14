//
//  SocialMessageCenterTests.swift
//  ClipTests
//

import CryptoKit
import XCTest
@testable import Clip

final class SocialMessageCenterTests: XCTestCase {

    private var scratchDirectory: URL!
    private var friendsStore: FriendsStore!
    private var readingListStore: ReadingListStore!
    private var transport: InMemoryMessageTransport!
    private var identityStore: InMemoryIdentityStore!
    private var ingestedItemURLs: [String] = []
    private var notifiedShares: [(username: String, title: String?)] = []
    private var center: SocialMessageCenter!
    private var me: UserIdentity!

    /// URLs of items the center accepted into the reading list this test.
    private var savedArticleURLs: [String] { ingestedItemURLs }

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SocialCenterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        friendsStore = FriendsStore(containerURL: scratchDirectory)
        readingListStore = ReadingListStore(containerURL: scratchDirectory)
        transport = InMemoryMessageTransport()
        identityStore = InMemoryIdentityStore()
        me = identityStore.createIdentity(username: "me", email: nil, phone: nil)
        ingestedItemURLs = []
        notifiedShares = []
        center = SocialMessageCenter(
            identityStore: identityStore,
            friendsStore: friendsStore,
            transport: transport,
            readingListStore: readingListStore,
            startIngest: { [weak self] item in self?.ingestedItemURLs.append(item.urlString) },
            notifyArticleShared: { [weak self] username, title in
                self?.notifiedShares.append((username, title))
            })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        super.tearDown()
    }

    private func makeSender(username: String = "alice") -> UserIdentity {
        UserIdentity(
            uuid: UUID(), username: username, email: nil, phone: nil,
            encryptionKey: Curve25519.KeyAgreement.PrivateKey(),
            signingKey: Curve25519.Signing.PrivateKey())
    }

    /// Seals a body from `sender` to `me` and drops it in the transport.
    private func inject(body: MessageBody, from sender: UserIdentity,
                        senderUUIDOverride: UUID? = nil) async throws {
        let payload = try MessageCrypto.seal(
            body: body,
            senderSigningKey: sender.signingKey,
            recipientEncryptionPublicKey: me.card.encryptionPublicKey)
        try await transport.send(
            payload: payload, to: me.uuid, from: senderUUIDOverride ?? sender.uuid)
    }

    func testFriendAddIsAcceptedAndRecordDeleted() async throws {
        let alice = makeSender()
        try await inject(body: .friendAdd(alice.card), from: alice)

        await center.processInbox()

        XCTAssertEqual(friendsStore.friend(withUUID: alice.uuid)?.card, alice.card)
        XCTAssertTrue(transport.messages.isEmpty)
        XCTAssertEqual(transport.deletedRecordIDs.count, 1)
    }

    func testInconsistentFriendAddRejectedButDeleted() async throws {
        let alice = makeSender()
        // Record claims a different sender UUID than the embedded card.
        try await inject(body: .friendAdd(alice.card), from: alice, senderUUIDOverride: UUID())

        await center.processInbox()

        XCTAssertNil(friendsStore.friend(withUUID: alice.uuid))
        XCTAssertTrue(transport.messages.isEmpty)
    }

    func testArticleFromFriendIsSavedWithAttribution() async throws {
        let alice = makeSender()
        friendsStore.add(alice.card)
        try await inject(body: .readingListItem(urlString: "https://example.com/x", title: "X"), from: alice)

        await center.processInbox()

        XCTAssertEqual(savedArticleURLs, ["https://example.com/x"])
        XCTAssertTrue(transport.messages.isEmpty)
        let saved = readingListStore.item(forURLString: "https://example.com/x")
        XCTAssertEqual(saved?.sharedByUsername, "alice")
    }

    func testNotifiesWhenFriendNotificationsEnabled() async throws {
        let alice = makeSender()
        friendsStore.add(alice.card)
        FriendNotificationSettings.setNotify(true, friendUUID: alice.uuid)
        defer { FriendNotificationSettings.setNotify(false, friendUUID: alice.uuid) }

        try await inject(
            body: .readingListItem(urlString: "https://example.com/x", title: "Hi"), from: alice)
        await center.processInbox()

        XCTAssertEqual(notifiedShares.count, 1)
        XCTAssertEqual(notifiedShares.first?.username, "alice")
        XCTAssertEqual(notifiedShares.first?.title, "Hi")
    }

    func testDoesNotNotifyWhenDisabled() async throws {
        let alice = makeSender()
        friendsStore.add(alice.card)
        FriendNotificationSettings.setNotify(false, friendUUID: alice.uuid)

        try await inject(
            body: .readingListItem(urlString: "https://example.com/y", title: nil), from: alice)
        await center.processInbox()

        XCTAssertTrue(notifiedShares.isEmpty)
    }

    func testIncomingDuplicateURLIsDroppedEntirely() async throws {
        let alice = makeSender()
        friendsStore.add(alice.card)
        // Already in the local list (saved by the user, no attribution).
        _ = readingListStore.add(urlString: "https://example.com/dup")

        try await inject(
            body: .readingListItem(urlString: "https://example.com/dup", title: nil), from: alice)
        await center.processInbox()

        XCTAssertTrue(savedArticleURLs.isEmpty) // no re-ingest
        XCTAssertNil(readingListStore.item(forURLString: "https://example.com/dup")?.sharedByUsername)
        XCTAssertTrue(transport.messages.isEmpty) // record still consumed
    }

    func testArticleFromNonFriendRejectedAndDeleted() async throws {
        let stranger = makeSender(username: "stranger")
        try await inject(body: .readingListItem(urlString: "https://example.com/x", title: nil), from: stranger)

        await center.processInbox()

        XCTAssertTrue(savedArticleURLs.isEmpty)
        XCTAssertTrue(transport.messages.isEmpty)
    }

    func testArticleWithMismatchedSigningKeyRejected() async throws {
        let alice = makeSender()
        var storedCard = alice.card
        // We know alice under a DIFFERENT signing key than she signs with.
        storedCard.signingPublicKey = Data(repeating: 7, count: 32)
        friendsStore.add(storedCard)

        try await inject(body: .readingListItem(urlString: "https://example.com/x", title: nil), from: alice)
        await center.processInbox()

        XCTAssertTrue(savedArticleURLs.isEmpty)
    }

    func testUnknownTypeIgnoredAndDeleted() async throws {
        let alice = makeSender()
        friendsStore.add(alice.card)
        try await inject(body: .unknown(type: "futureFeature"), from: alice)

        await center.processInbox()

        XCTAssertTrue(savedArticleURLs.isEmpty)
        XCTAssertTrue(friendsStore.items().count == 1)
        XCTAssertTrue(transport.messages.isEmpty)
    }

    func testUndecryptableMessageDeleted() async throws {
        let task = Task {
            try await transport.send(payload: Data("garbage".utf8), to: me.uuid, from: UUID())
        }
        _ = try await task.value

        await center.processInbox()

        XCTAssertTrue(transport.messages.isEmpty)
        XCTAssertEqual(transport.deletedRecordIDs.count, 1)
    }

    func testSendFriendAddWritesSealedRecord() async throws {
        let bob = makeSender(username: "bob")
        await center.sendFriendAdd(to: bob.card)

        XCTAssertEqual(transport.messages.count, 1)
        let message = try XCTUnwrap(transport.messages.first)
        XCTAssertEqual(message.recipientUUID, bob.uuid)
        XCTAssertEqual(message.senderUUID, me.uuid)

        // Bob can open it and gets our card.
        let (body, signingKey) = try MessageCrypto.open(
            payload: message.payload, recipientEncryptionKey: bob.encryptionKey)
        XCTAssertEqual(body, .friendAdd(me.card))
        XCTAssertEqual(signingKey, me.card.signingPublicKey)
    }

    func testSendArticleWritesSealedRecord() async throws {
        let bob = makeSender(username: "bob")
        friendsStore.add(bob.card)
        let friend = try XCTUnwrap(friendsStore.friend(withUUID: bob.uuid))

        try await center.sendArticle(
            urlString: "https://example.com/share", title: "Shared", to: friend)

        let message = try XCTUnwrap(transport.messages.first)
        let (body, _) = try MessageCrypto.open(
            payload: message.payload, recipientEncryptionKey: bob.encryptionKey)
        XCTAssertEqual(body, .readingListItem(urlString: "https://example.com/share", title: "Shared"))
    }
}
