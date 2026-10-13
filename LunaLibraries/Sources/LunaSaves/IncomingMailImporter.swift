//
//  IncomingMailImporter.swift
//  LunaSaves
//

import LunaMailAccount
import LunaMailTransport
import LunaSocial
import LunaStorage
import LunaModels
import Foundation
import CryptoKit

/// Opportunistically reads incoming mail on launch, foreground, and
/// background, through the connected email account, and:
///  - imports **Luna shares** (messages carrying the `X-Luna-Share` marker),
///    adding each recognized sender as a contact;
///  - imports **Luna-prefixed shares whose marker could not be recovered**.
///    It resolves the embedded original-content URL silently first, with no
///    CAPTCHA. It falls back to the rendered email body, with the title
///    prefix stripped, only if that URL is missing or cannot unlock that way;
///  - imports **matched newsletters** (the existing sender/subject filters) as
///    articles.
/// Luna mail is marked read as it is processed.
public final class IncomingMailImporter {

    public static let shared = IncomingMailImporter()

    private let store: SavesStore
    private let friends: FriendsStore
    private let accountStore: EmailAccountStore
    private let makeTransport: () -> EmailTransport?
    /// Guarded by `runningLock`: `importNewMail` is called concurrently from
    /// launch, foreground, and background refresh, so the coalescing check and
    /// set must be one atomic step.
    private var isRunning = false
    private let runningLock = NSLock()

    public init(store: SavesStore = .shared,
                friends: FriendsStore = .shared,
                accountStore: EmailAccountStore = .shared,
                makeTransport: (() -> EmailTransport?)? = nil) {
        self.store = store
        self.friends = friends
        self.accountStore = accountStore
        self.makeTransport = makeTransport ?? { MailTransportFactory.make(store: accountStore) }
    }

    /// Can run when an email account is connected and does not need recovery.
    public var isConfigured: Bool { accountStore.isReady }

    public struct ImportSummary: Equatable {
        public let processed: Int
        public let skipped: Int
        public init(processed: Int, skipped: Int) {
            self.processed = processed
            self.skipped = skipped
        }
    }

    public enum ImportError: Error, LocalizedError {
        case notConfigured, alreadyRunning, accountChanged, saveFailed
        public var errorDescription: String? {
            switch self {
            case .notConfigured: return L10n.string("Settings_email_pullNotConfigured")
            case .alreadyRunning: return L10n.string("Settings_email_pullBusy")
            case .accountChanged: return L10n.string("Settings_email_pullAccountChanged")
            case .saveFailed: return L10n.string("Settings_email_pullSaveFailed")
            }
        }
    }

    /// Automatic polls keep their existing cursor behavior and log failures.
    public func importNewMail() async {
        guard isConfigured else { return }
        do { _ = try await run(since: nil) }
        catch ImportError.alreadyRunning { }
        catch {
            DiagnosticLog.shared.record(
                "incoming mail fetch failed: \(String(describing: error))", category: "mail")
        }
    }

    /// Explicit recovery/backfill: reapply current filters to the past seven days.
    /// IMAP SINCE has day precision, so its window starts at midnight UTC.
    /// A recent scan never advances the automatic cursor, even when it finds
    /// newer messages, because doing so could skip older automatic-poll matches.
    public func importRecentMail(now: Date = Date()) async throws -> ImportSummary {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let since = calendar.startOfDay(for: now.addingTimeInterval(-7 * 24 * 60 * 60))
        return try await run(since: since)
    }

    private func run(since: Date?) async throws -> ImportSummary {
        guard let account = accountStore.account, isConfigured,
              let transport = makeTransport() else { throw ImportError.notConfigured }
        let alreadyRunning = runningLock.withLock {
            let wasRunning = isRunning
            if !wasRunning { isRunning = true }
            return wasRunning
        }
        guard !alreadyRunning else { throw ImportError.alreadyRunning }
        defer { runningLock.withLock { isRunning = false } }
        let result: FetchResult
        if let since {
            result = try await transport.fetchRecentShares(
                since: since, extraSenders: IncomingMailSettings.allowedSenders,
                extraSubjects: IncomingMailSettings.subjectFilters)
        } else {
            result = try await transport.fetchShares(
                after: IncomingMailSettings.cursor,
                extraSenders: IncomingMailSettings.allowedSenders,
                extraSubjects: IncomingMailSettings.subjectFilters)
        }
        var processed = 0
        var skipped = 0
        var toMarkRead: [String] = []
        for message in result.messages {
            try Task.checkCancellation()
            guard accountStore.account == account else {
                throw ImportError.accountChanged
            }
            let key = Self.messageKey(message, account: account, cursor: result.cursor)
            if try store.hasProcessedMail(key) {
                skipped += 1
                continue
            }
            // Preserve imports made before processing receipts existed. Those
            // builds used the provider's raw message id as the synthetic URL.
            if store.item(forURLString: "lunamail://\(message.id)")?.state == .ready {
                try store.recordProcessedMail(key)
                skipped += 1
                continue
            }
            let senderEmail = Self.address(from: message.from)
            if friends.isBlocked(senderEmail) {
                DiagnosticLog.shared.record(
                    "incoming mail: ignored blocked contact \(senderEmail)", category: "mail")
            } else if let marker = message.marker {
                _ = await handleLunaShare(marker, message: message)
            } else if Self.isLunaShareSubject(message.subject) {
                try await importUnmarkedLunaShare(message, messageKey: key)
            } else {
                try importNewsletter(message, messageKey: key)
            }
            try store.recordProcessedMail(key)
            processed += 1
            toMarkRead.append(message.id)
        }
        if !toMarkRead.isEmpty { try? await transport.markRead(toMarkRead) }
        guard accountStore.account == account else {
            throw ImportError.accountChanged
        }
        if since == nil { IncomingMailSettings.cursor = result.cursor }
        DiagnosticLog.shared.record(
            "incoming mail\(since == nil ? "" : " recent scan"): processed \(processed) message(s), skipped \(skipped) already processed", category: "mail")
        return ImportSummary(processed: processed, skipped: skipped)
    }

    /// Scope native IDs by mailbox/account and IMAP UIDVALIDITY. Message-ID,
    /// when present, survives UID renumbering and Graph folder moves. Hashing
    /// keeps addresses and server names out of synthetic saved URLs.
    static func messageKey(_ message: FetchedMessage, account: EmailAccount, cursor: MailCursor) -> String {
        let scope = [account.address.lowercased(), account.providerID.rawValue,
                     account.server?.imapHost.lowercased() ?? "graph"]
        let identity: String
        if let messageID = message.headers["message-id"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !messageID.isEmpty {
            identity = "message-id:\(messageID)"
        } else if case .imap(_, let validity) = cursor {
            identity = "imap:\(validity):\(message.id)"
        } else {
            identity = "graph:\(message.id)"
        }
        let data = Data((scope + [identity]).joined(separator: "\u{0}").utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Luna shares

    /// Routes a Luna share by sender. Returns true if the message was handled
    /// (and should be marked read).
    private func handleLunaShare(_ marker: LunaShareMarker, message: FetchedMessage) async -> Bool {
        let senderEmail = Self.address(from: message.from)
        guard Friend.isValidEmail(senderEmail) else { return false }
        guard !marker.url.isEmpty, URL(string: marker.url)?.scheme?.hasPrefix("http") == true
        else { return false }

        let contact = contactForRecognizedEmail(message, senderEmail: senderEmail)
        await autoImport(marker, from: contact)
        return true
    }

    /// Adds a recognized Luna sender as a contact, except for the connected
    /// account's own address. Self-sent messages still import normally.
    private func contactForRecognizedEmail(
        _ message: FetchedMessage, senderEmail: String
    ) -> Friend {
        let name = Self.displayName(from: message.from)
        if Self.sameAddress(senderEmail, accountStore.account?.address) {
            return Friend(email: senderEmail, name: name ?? accountStore.account?.displayName)
        }
        return friends.add(email: senderEmail, name: name)
    }

    /// Auto-imports an accepted friend's share into the saves list.
    private func autoImport(_ marker: LunaShareMarker, from friend: Friend) async {
        guard let item = store.addIfAbsent(urlString: marker.url, source: .email) else { return }
        store.setIncomingSender(
            email: friend.email, displayName: friend.displayName, for: item.id)
        await SavesIngestor.shared.ingest(item)

        let wasFirst = friends.markReceivedShare(email: friend.email)
        if wasFirst || friend.notifyOnEveryShare {
            NotificationManager.postShareReceived(
                fromName: friend.displayName, title: marker.title.isEmpty ? nil : marker.title)
        }
        DiagnosticLog.shared.record(
            "incoming mail: auto-imported share from contact \(friend.email)", category: "mail")
    }

    // MARK: - Luna-prefixed shares without a recoverable marker

    /// Handles a Luna-prefixed share whose `X-Luna-Share` marker could not be
    /// recovered — the provider stripped the header, or, for a long article,
    /// the mail fetch size cap clipped the hidden HTML marker block. Tries
    /// the embedded original-content URL first, through the same silent,
    /// non-CAPTCHA resolution every other save uses, so the reader gets the
    /// real article instead of Luna's own rendered copy. Falls back to the
    /// rendered email body only when the URL is missing or needs a CAPTCHA to
    /// unlock.
    private func importUnmarkedLunaShare(_ message: FetchedMessage, messageKey: String) async throws {
        let senderEmail = Self.address(from: message.from)
        guard Friend.isValidEmail(senderEmail) else { return }
        let contact = contactForRecognizedEmail(message, senderEmail: senderEmail)
        if let originalURL = Self.urls(in: message.bodyText).first {
            guard let item = store.addIfAbsent(urlString: originalURL.absoluteString, source: .email)
            else { return } // Already saved via this URL elsewhere.

            store.setIncomingSender(
                email: contact.email, displayName: contact.displayName, for: item.id)
            await SavesIngestor.shared.ingest(item)
            if store.item(withID: item.id)?.state == .ready { return }
            // Silent resolution failed — drop the stub and fall back to the
            // rendered email content below.
            store.delete(item)
        }
        try importFromBody(
            message, subjectOverride: Self.titleStrippingLunaPrefix(message.subject),
            contact: contact, messageKey: messageKey)
    }

    /// Whether the (decoded) subject carries Luna's own share prefix
    /// (`FilterGuide.subjectMatch`) — both mail transports always search for
    /// it, regardless of the user's configured sender/subject filters.
    static func isLunaShareSubject(_ subject: String) -> Bool {
        MailArticleBuilder.decodeEncodedWords(subject).hasPrefix(FilterGuide.subjectMatch)
    }

    /// The subject with Luna's share prefix removed (decoding RFC 2047
    /// encoded-words first, since the raw header may still be encoded), so a
    /// save's title never carries it.
    static func titleStrippingLunaPrefix(_ subject: String) -> String {
        let decoded = MailArticleBuilder.decodeEncodedWords(subject)
        guard decoded.hasPrefix(FilterGuide.subjectMatch) else { return decoded }
        return String(decoded.dropFirst(FilterGuide.subjectMatch.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Newsletters (existing sender/subject filters)

    private func importNewsletter(_ message: FetchedMessage, messageKey: String) throws {
        try importFromBody(message, subjectOverride: nil, contact: nil, messageKey: messageKey)
    }

    /// Saves an email using its own rendered body as the article content —
    /// the generic newsletter path, and the Luna-prefix fallback when the
    /// original-content URL is missing or needs user interaction to unlock.
    /// When set, `subjectOverride` replaces the raw subject with one that has
    /// Luna's subject prefix already stripped, so the saved title never
    /// carries it.
    private func importFromBody(
        _ message: FetchedMessage, subjectOverride: String?, contact: Friend?, messageKey: String
    ) throws {
        let incoming = IncomingMessage(
            uid: message.uid ?? 0, from: message.from, subject: subjectOverride ?? message.subject,
            date: message.date, contentType: message.headers["content-type"] ?? "",
            transferEncoding: message.headers["content-transfer-encoding"] ?? "",
            body: message.bodyText, urls: Self.urls(in: message.bodyText))

        if let content = MailArticleBuilder.article(from: incoming) {
            let url = "lunamail://\(messageKey)"
            let existing = store.item(forURLString: url)
            if existing?.state == .ready { return }
            guard let item = existing ?? store.addIfAbsent(urlString: url, source: .email)
            else { throw ImportError.saveFailed }
            recordSender(message, contact: contact, itemID: item.id)
            let ready = store.saveContent(content, for: item)
            // Article-kind hook for Kindle/ereader auto-send. A no-op in apps
            // without article handling — they have no send destination.
            guard ready.state == .ready else { throw ImportError.saveFailed }
            SaveReadiness.observer?.saveBecameReady(ready)
        } else if let url = incoming.urls.first, let item = store.addIfAbsent(
            urlString: url.absoluteString, source: .email) {
            recordSender(message, contact: contact, itemID: item.id)
            Task { await SavesIngestor.shared.ingest(item) }
        }
    }

    private func recordSender(_ message: FetchedMessage, contact: Friend?, itemID: UUID) {
        let email = contact?.email ?? Self.address(from: message.from)
        guard Friend.isValidEmail(email) else { return }
        let displayName = contact?.displayName
            ?? Self.displayName(from: message.from)
            ?? Friend.localPart(email)
        store.setIncomingSender(email: email, displayName: displayName, for: itemID)
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

    static func sameAddress(_ lhs: String, _ rhs: String?) -> Bool {
        guard let rhs else { return false }
        return Friend.normalize(lhs) == Friend.normalize(rhs)
    }

    private static func urls(in text: String) -> [URL] {
        GmailIMAPClient.extractURLs(from: text)
    }
}
