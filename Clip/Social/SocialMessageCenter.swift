//
//  SocialMessageCenter.swift
//  Clip
//

import Foundation
import os

/// Orchestrates social messaging: seals and sends friend adds and shared
/// articles, and drains the inbox (decrypt → verify → route → delete).
/// Called on launch, foreground, silent push, and pull-to-refresh.
final class SocialMessageCenter {

    static let shared = SocialMessageCenter()

    private let logger = Logger(subsystem: "com.hpiddy.clip", category: "social")
    private let identityStore: IdentityStoring
    private let friendsStore: FriendsStore
    private let transport: MessageTransport
    /// How an accepted shared article enters the reading list (injectable so
    /// tests don't touch the real ingestor).
    private let saveSharedArticle: (String) -> Void

    /// Prevents overlapping inbox drains (launch + push can race).
    private let drainLock = NSLock()
    private var isDraining = false

    init(identityStore: IdentityStoring = KeychainIdentityStore.shared,
         friendsStore: FriendsStore = .shared,
         transport: MessageTransport = CloudKitMessageTransport(),
         saveSharedArticle: ((String) -> Void)? = nil) {
        self.identityStore = identityStore
        self.friendsStore = friendsStore
        self.transport = transport
        self.saveSharedArticle = saveSharedArticle ?? { urlString in
            let item = ReadingListStore.shared.add(urlString: urlString)
            Task { await ReadingListIngestor.shared.ingest(item) }
        }
    }

    /// Current messaging availability (iCloud account status).
    func availability() async -> MessagingAvailability {
        await transport.availability()
    }

    // MARK: - Outgoing

    /// Tells `card`'s owner to add us back (the second half of a
    /// bi-directional friend add). Failures are logged, not retried.
    func sendFriendAdd(to card: IdentityCard) async {
        guard let identity = identityStore.loadIdentity() else { return }
        do {
            let payload = try MessageCrypto.seal(
                body: .friendAdd(identity.card),
                senderSigningKey: identity.signingKey,
                recipientEncryptionPublicKey: card.encryptionPublicKey)
            try await transport.send(payload: payload, to: card.uuid, from: identity.uuid)
        } catch {
            logger.error("friendAdd send failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Sends a reading-list article to a friend. Throws so the UI can show
    /// the failure.
    func sendArticle(urlString: String, title: String?, to friend: Friend) async throws {
        guard let identity = identityStore.loadIdentity() else {
            throw MessageCrypto.CryptoError(reason: "no identity")
        }
        let payload = try MessageCrypto.seal(
            body: .readingListItem(urlString: urlString, title: title),
            senderSigningKey: identity.signingKey,
            recipientEncryptionPublicKey: friend.card.encryptionPublicKey)
        try await transport.send(payload: payload, to: friend.card.uuid, from: identity.uuid)
    }

    // MARK: - Incoming

    /// Installs the inbox subscription (idempotent; call every launch).
    func ensureSubscription() async {
        guard let identity = identityStore.loadIdentity() else { return }
        do {
            try await transport.ensureSubscription(for: identity.uuid)
        } catch {
            logger.error("subscription failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Fetches everything addressed to us, processes each message, and
    /// deletes it. Undecryptable or unrecognized messages are deleted and
    /// ignored (forward compatibility). Safe to call repeatedly.
    func processInbox() async {
        guard let identity = identityStore.loadIdentity() else { return }

        drainLock.lock()
        let alreadyDraining = isDraining
        if !alreadyDraining { isDraining = true }
        drainLock.unlock()
        guard !alreadyDraining else { return }
        defer {
            drainLock.lock()
            isDraining = false
            drainLock.unlock()
        }

        let records: [InboxRecord]
        do {
            records = try await transport.fetchInbox(for: identity.uuid)
        } catch {
            logger.error("inbox fetch failed: \(String(describing: error), privacy: .public)")
            return
        }

        var seenRecordIDs = Set<String>()
        for record in records {
            guard seenRecordIDs.insert(record.recordID).inserted else { continue }
            process(record, identity: identity)
            try? await transport.delete(recordID: record.recordID)
        }
    }

    private func process(_ record: InboxRecord, identity: UserIdentity) {
        let body: MessageBody
        let senderSigningKey: Data
        do {
            (body, senderSigningKey) = try MessageCrypto.open(
                payload: record.payload, recipientEncryptionKey: identity.encryptionKey)
        } catch {
            logger.info("dropping undecryptable message \(record.recordID, privacy: .public)")
            return
        }

        switch body {
        case .friendAdd(let card):
            // Trust-on-first-use, but the card must be self-consistent: the
            // embedded identity must match both the signer and the record's
            // plaintext sender.
            guard card.signingPublicKey == senderSigningKey,
                  card.uuid == record.senderUUID
            else {
                logger.info("dropping inconsistent friendAdd from \(record.senderUUID, privacy: .public)")
                return
            }
            friendsStore.add(card)
            logger.info("added friend \(card.username, privacy: .public) via message")

        case .readingListItem(let urlString, _):
            // Only friends may push links, and the signature must match the
            // key we stored when we added them.
            guard let friend = friendsStore.friend(withUUID: record.senderUUID),
                  friend.card.signingPublicKey == senderSigningKey
            else {
                logger.info("dropping article from non-friend \(record.senderUUID, privacy: .public)")
                return
            }
            guard URL(string: urlString) != nil else { return }
            saveSharedArticle(urlString)
            logger.info("accepted shared article from \(friend.card.username, privacy: .public)")

        case .unknown(let type):
            logger.info("ignoring unknown message type \(type, privacy: .public)")
        }
    }
}
