//
//  IncomingMailImporter.swift
//  LunaReadingList
//

import LunaMail
import LunaMailAccount
import LunaMailTransport
import LunaSend
import LunaSocial
import LunaStorage
import LunaModels
import Foundation

/// Opportunistically reads incoming mail (on launch/foreground/background) via
/// the connected email account and:
///  - imports **Luna shares** (messages carrying the `X-Luna-Share` marker) —
///    auto-importing those from accepted friends, and queuing those from
///    strangers into the pending-requests moderation list;
///  - imports **matched newsletters** (the existing sender/subject filters) as
///    articles.
/// Luna mail is marked read as it's processed.
public final class IncomingMailImporter {

    public static let shared = IncomingMailImporter()

    private let store: ReadingListStore
    private let friends: FriendsStore
    private let pending: PendingRequestsStore
    private let accountStore: EmailAccountStore
    /// Guarded by `runningLock`: `importNewMail` is called concurrently from
    /// launch, foreground, and background refresh, so the coalescing check and
    /// set must be one atomic step.
    private var isRunning = false
    private let runningLock = NSLock()

    public init(store: ReadingListStore = .shared,
                friends: FriendsStore = .shared,
                pending: PendingRequestsStore = .shared,
                accountStore: EmailAccountStore = .shared) {
        self.store = store
        self.friends = friends
        self.pending = pending
        self.accountStore = accountStore
    }

    /// Can run when an email account is connected.
    public var isConfigured: Bool { accountStore.isConfigured }

    /// Fetches and processes new mail. Safe to call repeatedly; coalesces overlaps.
    public func importNewMail() async {
        guard isConfigured else { return }
        guard let transport = MailTransportFactory.make(store: accountStore) else { return }
        runningLock.lock()
        let alreadyRunning = isRunning
        if !alreadyRunning { isRunning = true }
        runningLock.unlock()
        guard !alreadyRunning else { return }
        defer {
            runningLock.lock()
            isRunning = false
            runningLock.unlock()
        }

        let cursor = MailCursor(
            uid: IncomingMailSettings.lastUID,
            uidValidity: IncomingMailSettings.uidValidity,
            token: IncomingMailSettings.cursorToken)

        do {
            let result = try await transport.fetchShares(
                after: cursor,
                extraSenders: IncomingMailSettings.allowedSenders,
                extraSubjects: IncomingMailSettings.subjectFilters)

            var toMarkRead: [String] = []
            for message in result.messages {
                if let marker = message.marker {
                    if await handleLunaShare(marker, message: message) {
                        toMarkRead.append(message.id)
                    }
                } else {
                    importNewsletter(message)
                    toMarkRead.append(message.id)
                }
            }
            if !toMarkRead.isEmpty { try? await transport.markRead(toMarkRead) }

            IncomingMailSettings.lastUID = result.cursor.uid
            IncomingMailSettings.uidValidity = result.cursor.uidValidity
            IncomingMailSettings.cursorToken = result.cursor.token
            DiagnosticLog.shared.record(
                "incoming mail: processed \(result.messages.count) message(s)", category: "mail")
        } catch {
            DiagnosticLog.shared.record(
                "incoming mail fetch failed: \(String(describing: error))", category: "mail")
        }
    }

    // MARK: - Luna shares

    /// Routes a Luna share by sender. Returns true if the message was handled
    /// (and should be marked read).
    private func handleLunaShare(_ marker: LunaShareMarker, message: FetchedMessage) async -> Bool {
        let senderEmail = Self.address(from: message.from)
        guard Friend.isValidEmail(senderEmail) else { return false }
        guard !marker.url.isEmpty, URL(string: marker.url)?.scheme?.hasPrefix("http") == true
        else { return false }

        if let friend = friends.friend(withEmail: senderEmail) {
            await autoImport(marker, from: friend)
        } else {
            queuePending(marker, message: message, senderEmail: senderEmail)
        }
        return true
    }

    /// Auto-imports an accepted friend's share into the reading list.
    private func autoImport(_ marker: LunaShareMarker, from friend: Friend) async {
        guard let item = store.addIfAbsent(urlString: marker.url, source: .email) else { return }
        store.setChannelName(friend.displayName, for: item.id)
        await ReadingListIngestor.shared.ingest(item)

        let wasFirst = friends.markReceivedShare(email: friend.email)
        if wasFirst || friend.notifyOnEveryShare {
            NotificationManager.postShareReceived(
                fromName: friend.displayName, title: marker.title.isEmpty ? nil : marker.title)
        }
        DiagnosticLog.shared.record(
            "incoming mail: auto-imported share from friend \(friend.email)", category: "mail")
    }

    /// Queues a stranger's share for moderation (not imported yet).
    private func queuePending(
        _ marker: LunaShareMarker, message: FetchedMessage, senderEmail: String
    ) {
        guard !pending.contains(urlString: marker.url, senderEmail: senderEmail) else { return }
        let senderName = Self.displayName(from: message.from)
        pending.add(PendingRequest(
            senderEmail: senderEmail, senderName: senderName,
            urlString: marker.url, title: marker.title.isEmpty ? nil : marker.title,
            kind: marker.kind, messageID: message.id))
        NotificationManager.postPendingRequest(
            fromName: senderName ?? Friend.localPart(senderEmail),
            title: marker.title.isEmpty ? nil : marker.title)
        DiagnosticLog.shared.record(
            "incoming mail: queued pending request from \(senderEmail)", category: "mail")
    }

    // MARK: - Newsletters (existing sender/subject filters)

    private func importNewsletter(_ message: FetchedMessage) {
        let incoming = IncomingMessage(
            uid: message.uid ?? 0, from: message.from, subject: message.subject,
            date: message.date, contentType: message.headers["content-type"] ?? "",
            transferEncoding: message.headers["content-transfer-encoding"] ?? "",
            body: message.bodyText, urls: Self.urls(in: message.bodyText))

        if let content = MailArticleBuilder.article(from: incoming) {
            let item = store.add(urlString: "lunamail://\(message.id)", source: .email)
            if let sender = MailArticleBuilder.senderName(from: message.from) {
                store.setChannelName(sender, for: item.id)
            }
            let ready = store.saveContent(content, for: item)
            if ready.state == .ready { ArticleSendCoordinator.shared.articleBecameReady(ready) }
        } else if let url = incoming.urls.first, let item = store.addIfAbsent(
            urlString: url.absoluteString, source: .email) {
            Task { await ReadingListIngestor.shared.ingest(item) }
        }
    }

    // MARK: - Address parsing

    /// The email address from a `From` header (`"Name" <a@b.com>` → `a@b.com`).
    static func address(from raw: String) -> String {
        if let open = raw.firstIndex(of: "<"), let close = raw.firstIndex(of: ">"), open < close {
            return Friend.normalize(String(raw[raw.index(after: open)..<close]))
        }
        return Friend.normalize(raw)
    }

    /// The display name from a `From` header, if any.
    static func displayName(from raw: String) -> String? {
        MailArticleBuilder.senderName(from: raw)
    }

    private static func urls(in text: String) -> [URL] {
        GmailIMAPClient.extractURLs(from: text)
    }
}
