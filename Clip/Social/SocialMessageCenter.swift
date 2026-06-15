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
    private let readingListStore: ReadingListStore
    /// Kicks ingestion for an accepted shared article; injectable so tests
    /// don't touch the real ingestor.
    private let startIngest: (ReadingListItem) -> Void
    /// Posts the "friend shared an article" local notification (username,
    /// title); injectable so tests don't touch UNUserNotificationCenter.
    private let notifyArticleShared: (String, String?) -> Void

    /// Prevents overlapping inbox drains (launch + push can race).
    private let drainLock = NSLock()
    private var isDraining = false

    /// Delays (seconds) between inbox re-fetches when a push- or
    /// background-refresh-triggered drain finds nothing. A silent push fires
    /// the instant a sender creates the record, but the PUBLIC database's query
    /// index is eventually consistent — the record often isn't returned by a
    /// query until a few seconds later. Retrying closes that gap. Overridable
    /// in tests to avoid real delays.
    var pushRetryDelaysSeconds: [UInt64] = [2, 4, 8]

    init(identityStore: IdentityStoring = KeychainIdentityStore.shared,
         friendsStore: FriendsStore = .shared,
         transport: MessageTransport = CloudKitMessageTransport(),
         readingListStore: ReadingListStore = .shared,
         startIngest: ((ReadingListItem) -> Void)? = nil,
         notifyArticleShared: ((String, String?) -> Void)? = nil) {
        self.identityStore = identityStore
        self.friendsStore = friendsStore
        self.transport = transport
        self.readingListStore = readingListStore
        self.startIngest = startIngest ?? { item in
            Task { await ReadingListIngestor.shared.ingest(item) }
        }
        self.notifyArticleShared = notifyArticleShared ?? { username, title in
            NotificationManager.postArticleShared(fromUsername: username, title: title)
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
    /// the failure. User-initiated sends feed the share-suggestion streak;
    /// automated (always-share) sends don't.
    func sendArticle(
        urlString: String, title: String?, to friend: Friend,
        countsAsManualShare: Bool = true
    ) async throws {
        guard let identity = identityStore.loadIdentity() else {
            throw MessageCrypto.CryptoError(reason: "no identity")
        }
        let payload = try MessageCrypto.seal(
            body: .readingListItem(urlString: urlString, title: title),
            senderSigningKey: identity.signingKey,
            recipientEncryptionPublicKey: friend.card.encryptionPublicKey)
        do {
            try await transport.send(payload: payload, to: friend.card.uuid, from: identity.uuid)
            DiagnosticLog.shared.record(
                "sent article to \(friend.card.username) [\(friend.card.uuid.uuidString)]",
                category: "social")
            // Teach iOS this conversation so the friend surfaces in the share sheet.
            ShareIntentDonor.donateShare(to: friend.card)
        } catch {
            DiagnosticLog.shared.record(
                "send article to \(friend.card.username) FAILED: \(String(describing: error))",
                category: "social")
            throw error
        }
        if countsAsManualShare {
            ShareSuggestionStore.shared.recordManualShare(
                urlString: urlString,
                friendUUID: friend.card.uuid,
                friendUsername: friend.card.username)
        }
    }

    /// Always-share automation for a newly saved URL: fire-and-forget send
    /// that never feeds the suggestion streak.
    func autoShare(urlString: String, toFriendUUID uuid: UUID) async {
        guard let friend = friendsStore.friend(withUUID: uuid) else { return }
        do {
            try await sendArticle(
                urlString: urlString, title: nil, to: friend, countsAsManualShare: false)
            logger.info("auto-shared to \(friend.card.username, privacy: .public)")
        } catch {
            logger.error("auto-share failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Sends any friend-shares the share extension queued (it can't send
    /// directly). Call on launch and foreground.
    func drainPendingFriendShares() async {
        let pending = PendingFriendShareStore.drainAll()
        for share in pending {
            guard let friend = friendsStore.friend(withUUID: share.friendUUID) else {
                logger.info("pending share for unknown friend \(share.friendUUID, privacy: .public)")
                continue
            }
            do {
                try await sendArticle(urlString: share.urlString, title: nil, to: friend)
                DiagnosticLog.shared.record(
                    "sent share-sheet share to \(friend.card.username)", category: "social")
            } catch {
                DiagnosticLog.shared.record(
                    "pending share to \(friend.card.username) FAILED: \(String(describing: error))",
                    category: "social")
            }
        }
    }

    // MARK: - Incoming

    /// Installs the inbox subscription (idempotent; call every launch).
    func ensureSubscription() async {
        guard let identity = identityStore.loadIdentity() else { return }
        do {
            try await transport.ensureSubscription(for: identity.uuid)
            logger.notice("inbox subscription ensured for \(identity.uuid.uuidString, privacy: .public)")
            DiagnosticLog.shared.record(
                "inbox subscription ensured for \(identity.uuid.uuidString)", category: "social")
        } catch {
            logger.error("subscription failed: \(String(describing: error), privacy: .public)")
            DiagnosticLog.shared.record(
                "inbox subscription FAILED: \(String(describing: error))", category: "social")
        }
    }

    /// Handles a silent push. If the push carried the record's fields (the fast
    /// path — no query, so no public-DB index lag), processes that record
    /// directly. Otherwise falls back to draining the inbox by query.
    func processPush(userInfo: [AnyHashable: Any]) async {
        guard let identity = identityStore.loadIdentity() else { return }
        if let record = transport.inboxRecord(fromPush: userInfo) {
            logger.notice("push carried record \(record.recordID, privacy: .public)")
            DiagnosticLog.shared.record(
                "push carried record \(record.recordID) (no fetch needed)", category: "social")
            process(record, identity: identity)
            try? await transport.delete(recordID: record.recordID)
        } else {
            DiagnosticLog.shared.record(
                "push had no record fields; draining by query", category: "social")
            await processInbox(trigger: "push")
        }
    }

    /// Fetches everything addressed to us, processes each message, and
    /// deletes it. Undecryptable or unrecognized messages are deleted and
    /// ignored (forward compatibility). Safe to call repeatedly.
    func processInbox(trigger: String = "manual") async {
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

        // A push fires the moment a record is created, but the public DB query
        // index lags by a few seconds, so an immediate query can miss it. When
        // a push (or bg refresh) signals an arrival, retry the query before
        // concluding the inbox is empty. User-initiated drains don't retry.
        let retryDelays: [UInt64] =
            (trigger == "push" || trigger == "bgRefresh") ? pushRetryDelaysSeconds : []

        var records: [InboxRecord] = []
        var attempt = 0
        while true {
            do {
                records = try await transport.fetchInbox(for: identity.uuid)
            } catch {
                logger.error("inbox fetch failed (\(trigger, privacy: .public)): \(String(describing: error), privacy: .public)")
                DiagnosticLog.shared.record(
                    "processInbox (\(trigger)) FAILED: \(String(describing: error))", category: "social")
                return
            }
            if !records.isEmpty || attempt >= retryDelays.count { break }
            try? await Task.sleep(nanoseconds: retryDelays[attempt] * 1_000_000_000)
            attempt += 1
        }
        logger.notice("processInbox (\(trigger, privacy: .public)) fetched \(records.count) record(s) after \(attempt + 1) attempt(s) for \(identity.uuid.uuidString, privacy: .public)")
        DiagnosticLog.shared.record(
            "processInbox (\(trigger)) fetched \(records.count) record(s) after \(attempt + 1) attempt(s)", category: "social")

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

        case .readingListItem(let urlString, let title):
            // Only friends may push links, and the signature must match the
            // key we stored when we added them.
            guard let friend = friendsStore.friend(withUUID: record.senderUUID),
                  friend.card.signingPublicKey == senderSigningKey
            else {
                logger.info("dropping article from non-friend \(record.senderUUID, privacy: .public)")
                return
            }
            guard URL(string: urlString) != nil else { return }
            // Recipient-side dedupe: an incoming share of a URL we already
            // have is dropped entirely (no re-ingest, no attribution change).
            guard readingListStore.item(forURLString: urlString) == nil else {
                logger.info("dropping duplicate shared article")
                return
            }
            let saved = readingListStore.add(urlString: urlString)
            readingListStore.setSharedBy(friend.card.username, for: saved.id)
            startIngest(saved)
            logger.info("accepted shared article from \(friend.card.username, privacy: .public)")
            DiagnosticLog.shared.record(
                "accepted shared article from \(friend.card.username)", category: "social")
            if FriendNotificationSettings.isNotifyEnabled(friendUUID: friend.card.uuid) {
                notifyArticleShared(friend.card.username, title)
            }

        case .unknown(let type):
            logger.info("ignoring unknown message type \(type, privacy: .public)")
        }
    }
}
