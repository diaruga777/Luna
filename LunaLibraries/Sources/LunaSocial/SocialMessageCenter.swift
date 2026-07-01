//
//  SocialMessageCenter.swift
//  Luna
//

import LunaStorage
import LunaURLClassification
import LunaModels
import Foundation
import os

/// Orchestrates social messaging: seals and sends friend adds and shared
/// articles, and drains the inbox (decrypt → verify → route → delete).
/// Called on launch, foreground, silent push, and pull-to-refresh.
public final class SocialMessageCenter {

    public static let shared = SocialMessageCenter()

    /// How a received friend-shared article is ingested. Injected by the app at
    /// launch (the ingestor lives above the social layer); nil in extensions/tests.
    public static var ingestHandler: ((ReadingListItem) -> Void)?

    /// Records (itemID, personUUID, username) of an outgoing share into the semantic
    /// index. Injected by the app (the semantic layer sits above social); nil otherwise.
    public static var shareRecorder: ((UUID, UUID, String) -> Void)?

    private let logger = Logger(subsystem: "com.hsanabria.luna", category: "social")
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
    /// Posts the first-ever-share notification (username, friend UUID for the
    /// settings deep link); injectable for tests.
    private let notifyFirstShare: (String, UUID) -> Void
    /// Posts the "X added you as a friend" notification (username); injectable for tests.
    private let notifyFriendAdded: (String) -> Void

    /// Prevents overlapping inbox drains (launch + push can race).
    private let drainLock = NSLock()
    private var isDraining = false

    /// Delays (seconds) between inbox re-fetches when a push- or
    /// background-refresh-triggered drain finds nothing. A silent push fires
    /// the instant a sender creates the record, but the PUBLIC database's query
    /// index is eventually consistent — the record often isn't returned by a
    /// query until a few seconds later. Retrying closes that gap. Overridable
    /// in tests to avoid real delays.
    public var pushRetryDelaysSeconds: [UInt64] = [2, 4, 8]

    public init(identityStore: IdentityStoring = KeychainIdentityStore.shared,
         friendsStore: FriendsStore = .shared,
         transport: MessageTransport = CloudKitMessageTransport(),
         readingListStore: ReadingListStore = .shared,
         startIngest: ((ReadingListItem) -> Void)? = nil,
         notifyArticleShared: ((String, String?) -> Void)? = nil,
         notifyFirstShare: ((String, UUID) -> Void)? = nil,
         notifyFriendAdded: ((String) -> Void)? = nil) {
        self.identityStore = identityStore
        self.friendsStore = friendsStore
        self.transport = transport
        self.readingListStore = readingListStore
        self.startIngest = startIngest ?? { item in
            SocialMessageCenter.ingestHandler?(item)
        }
        self.notifyArticleShared = notifyArticleShared ?? { username, title in
            NotificationManager.postArticleShared(fromUsername: username, title: title)
        }
        self.notifyFirstShare = notifyFirstShare ?? { username, friendUUID in
            NotificationManager.postFirstShare(fromUsername: username, friendUUID: friendUUID)
        }
        self.notifyFriendAdded = notifyFriendAdded ?? { username in
            NotificationManager.postFriendAdded(fromUsername: username)
        }
    }

    /// Decides whether/how to notify the user of a received share. The FIRST share
    /// ever from a friend always notifies (with a hint to enable future ones);
    /// after that, it honors the per-friend toggle.
    private func notifyOfReceivedShare(from friend: Friend, title: String?) {
        let friendUUID = friend.card.uuid
        if FriendNotificationSettings.hasSharedBefore(friendUUID: friendUUID) {
            if FriendNotificationSettings.isNotifyEnabled(friendUUID: friendUUID) {
                notifyArticleShared(friend.card.username, title)
            }
        } else {
            FriendNotificationSettings.markHasShared(friendUUID: friendUUID)
            notifyFirstShare(friend.card.username, friendUUID)
        }
    }

    /// Current messaging availability (iCloud account status).
    public func availability() async -> MessagingAvailability {
        await transport.availability()
    }

    // MARK: - Outgoing

    /// Tells `card`'s owner to add us back (the second half of a
    /// bi-directional friend add). Failures are logged, not retried.
    public func sendFriendAdd(to card: IdentityCard) async {
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
    public func sendArticle(
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
        let sharedItem = readingListStore.item(forURLString: urlString)
        if countsAsManualShare {
            ShareSuggestionStore.shared.recordManualShare(
                urlString: urlString,
                channelName: sharedItem?.channelName,
                friendUUID: friend.card.uuid,
                friendUsername: friend.card.username)
        }
        // Remember what we shared with this friend, to drive semantic
        // suggestions later (cheap: records the item id, no model loaded here).
        if let itemID = sharedItem?.id {
            SocialMessageCenter.shareRecorder?(itemID, friend.card.uuid, friend.card.username)
        }
    }

    /// Sends a URL-less music/podcast item to a friend (the new `mediaItem`
    /// case). Used to share songs/episodes that have no shareable http URL.
    public func sendMediaItem(
        kind: ContentPlatform, creator: String, title: String, to friend: Friend
    ) async throws {
        guard let identity = identityStore.loadIdentity() else {
            throw MessageCrypto.CryptoError(reason: "no identity")
        }
        let payload = try MessageCrypto.seal(
            body: .mediaItem(kind: kind, creator: creator, title: title),
            senderSigningKey: identity.signingKey,
            recipientEncryptionPublicKey: friend.card.encryptionPublicKey)
        try await transport.send(payload: payload, to: friend.card.uuid, from: identity.uuid)
        ShareIntentDonor.donateShare(to: friend.card)
        DiagnosticLog.shared.record(
            "sent media item to \(friend.card.username)", category: "social")
    }

    /// Sends a price tracker to a friend (the `priceTracker` case): all watched
    /// store URLs plus the current best price and alert threshold, so the
    /// recipient recreates the same tracker.
    public func sendPriceTracker(_ tracker: PriceTracker, to friend: Friend) async throws {
        guard let identity = identityStore.loadIdentity() else {
            throw MessageCrypto.CryptoError(reason: "no identity")
        }
        let payload = try MessageCrypto.seal(
            body: .priceTracker(PriceTrackerShare(tracker: tracker)),
            senderSigningKey: identity.signingKey,
            recipientEncryptionPublicKey: friend.card.encryptionPublicKey)
        try await transport.send(payload: payload, to: friend.card.uuid, from: identity.uuid)
        ShareIntentDonor.donateShare(to: friend.card)
        DiagnosticLog.shared.record(
            "sent price tracker to \(friend.card.username)", category: "social")
    }

    /// Always-share automation for a newly saved URL: fire-and-forget send
    /// that never feeds the suggestion streak.
    public func autoShare(urlString: String, toFriendUUID uuid: UUID) async {
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
    public func drainPendingFriendShares() async {
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
    public func ensureSubscription() async {
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

    /// Handles a silent push. The push carries the triggering record's ID, so we
    /// fetch THAT record by ID (strongly consistent — no eventually-consistent
    /// query-index lag, no retry). Falls back to a query drain only if the push
    /// carried no ID or the fetch failed (e.g. a coalesced push).
    public func processPush(userInfo: [AnyHashable: Any]) async {
        guard let identity = identityStore.loadIdentity() else { return }
        if let recordID = transport.recordID(fromPush: userInfo),
           let record = try? await transport.fetchRecord(recordID: recordID) {
            logger.notice("push fetched record \(recordID, privacy: .public) by id")
            DiagnosticLog.shared.record(
                "push fetched record \(recordID) by id (strongly consistent)", category: "social")
            process(record, identity: identity)
            try? await transport.delete(recordID: record.recordID)
        } else {
            DiagnosticLog.shared.record(
                "push had no usable record id; draining by query", category: "social")
            await processInbox(trigger: "push")
        }
    }

    /// Fetches everything addressed to us, processes each message, and
    /// deletes it. Undecryptable or unrecognized messages are deleted and
    /// ignored (forward compatibility). Safe to call repeatedly.
    public func processInbox(trigger: String = "manual") async {
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
        // index lags by a few seconds, so an immediate query can miss it — only
        // a push retries the query before concluding the inbox is empty. The
        // background refresh and user-initiated drains do a single fetch (a
        // periodic poll re-checks soon enough; no need to burn time retrying).
        let retryDelays: [UInt64] = trigger == "push" ? pushRetryDelaysSeconds : []

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
            // Only notify when this is a genuinely new friend (not a re-add of one we
            // already have), so a re-sent friendAdd can't spam the notification.
            let alreadyFriend = friendsStore.friend(withUUID: card.uuid) != nil
            friendsStore.add(card)
            logger.info("added friend \(card.username, privacy: .public) via message")
            if !alreadyFriend { notifyFriendAdded(card.username) }

        case .readingListItem(let urlString, let title):
            // Only friends may push links, and the signature must match the
            // key we stored when we added them.
            guard let friend = friendsStore.friend(withUUID: record.senderUUID),
                  friend.card.signingPublicKey == senderSigningKey
            else {
                logger.info("dropping article from non-friend \(record.senderUUID, privacy: .public)")
                return
            }
            guard let url = URLUnwrapper.ingestURL(from: urlString) else { return }
            // Recipient-side dedupe via the store's single URL-existence authority:
            // an incoming share of a URL we already have is dropped entirely (no
            // re-ingest, no attribution change).
            guard let saved = readingListStore.addIfAbsent(
                urlString: url.absoluteString, source: .friendShare) else {
                logger.info("dropping duplicate shared article")
                return
            }
            readingListStore.setSharedBy(friend.card.username, for: saved.id)
            startIngest(saved)
            logger.info("accepted shared article from \(friend.card.username, privacy: .public)")
            DiagnosticLog.shared.record(
                "accepted shared article from \(friend.card.username)", category: "social")
            notifyOfReceivedShare(from: friend, title: title)

        case .mediaItem(let kind, let creator, let title):
            guard let friend = friendsStore.friend(withUUID: record.senderUUID),
                  friend.card.signingPublicKey == senderSigningKey
            else {
                logger.info("dropping media item from non-friend \(record.senderUUID, privacy: .public)")
                return
            }
            let key = MediaItemKey.url(platform: kind, creator: creator, title: title)
            guard readingListStore.item(forURLString: key) == nil else {
                logger.info("dropping duplicate shared media item")
                return
            }
            let saved = readingListStore.createURLlessMediaItem(
                platform: kind, creator: creator, title: title)
            readingListStore.setSharedBy(friend.card.username, for: saved.id)
            notifyOfReceivedShare(from: friend, title: title)

        case .priceTracker(let share):
            guard let friend = friendsStore.friend(withUUID: record.senderUUID),
                  friend.card.signingPublicKey == senderSigningKey
            else {
                logger.info("dropping price tracker from non-friend \(record.senderUUID, privacy: .public)")
                return
            }
            guard let rawFirstURL = share.storeURLStrings.first,
                  let firstURL = URLUnwrapper.ingestURL(from: rawFirstURL)?.absoluteString
            else { return }
            guard let tracker = share.makeTracker() else { return }
            // Dedupe on the first store URL like other shared items, via the same
            // store authority.
            guard let saved = readingListStore.addIfAbsent(urlString: firstURL, source: .friendShare) else {
                logger.info("dropping duplicate shared price tracker")
                return
            }
            readingListStore.savePriceTracker(tracker, for: saved.id)
            readingListStore.setSharedBy(friend.card.username, for: saved.id)
            notifyOfReceivedShare(from: friend, title: share.productName)
            logger.info("accepted shared price tracker from \(friend.card.username, privacy: .public)")

        case .unknown(let type):
            logger.info("ignoring unknown message type \(type, privacy: .public)")
        }
    }
}
