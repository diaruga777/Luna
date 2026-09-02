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
    /// Guarded by `runningLock`: `importNewMail` is called concurrently from
    /// launch, foreground, and background refresh, so the coalescing check and
    /// set must be one atomic step.
    private var isRunning = false
    private let runningLock = NSLock()

    public init(store: SavesStore = .shared,
                friends: FriendsStore = .shared,
                accountStore: EmailAccountStore = .shared) {
        self.store = store
        self.friends = friends
        self.accountStore = accountStore
    }

    /// Can run when an email account is connected and does not need recovery.
    public var isConfigured: Bool { accountStore.isReady }

    /// Fetches and processes new mail. Safe to call repeatedly; coalesces overlaps.
    public func importNewMail() async {
        guard isConfigured else { return }
        guard let transport = MailTransportFactory.make(store: accountStore) else { return }
        let alreadyRunning = runningLock.withLock {
            let wasRunning = isRunning
            if !wasRunning { isRunning = true }
            return wasRunning
        }
        guard !alreadyRunning else { return }
        defer { runningLock.withLock { isRunning = false } }

        do {
            let result = try await transport.fetchShares(
                after: IncomingMailSettings.cursor,
                extraSenders: IncomingMailSettings.allowedSenders,
                extraSubjects: IncomingMailSettings.subjectFilters)

            var toMarkRead: [String] = []
            for message in result.messages {
                let senderEmail = Self.address(from: message.from)
                if friends.isBlocked(senderEmail) {
                    DiagnosticLog.shared.record(
                        "incoming mail: ignored blocked contact \(senderEmail)", category: "mail")
                    toMarkRead.append(message.id)
                    continue
                }
                if let marker = message.marker {
                    if await handleLunaShare(marker, message: message) {
                        toMarkRead.append(message.id)
                    }
                } else if Self.isLunaShareSubject(message.subject) {
                    await importUnmarkedLunaShare(message)
                    toMarkRead.append(message.id)
                } else {
                    importNewsletter(message)
                    toMarkRead.append(message.id)
                }
            }
            if !toMarkRead.isEmpty { try? await transport.markRead(toMarkRead) }

            IncomingMailSettings.cursor = result.cursor
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
    private func importUnmarkedLunaShare(_ message: FetchedMessage) async {
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
        importFromBody(
            message, subjectOverride: Self.titleStrippingLunaPrefix(message.subject),
            contact: contact)
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

    private func importNewsletter(_ message: FetchedMessage) {
        importFromBody(message, subjectOverride: nil, contact: nil)
    }

    /// Saves an email using its own rendered body as the article content —
    /// the generic newsletter path, and the Luna-prefix fallback when the
    /// original-content URL is missing or needs user interaction to unlock.
    /// When set, `subjectOverride` replaces the raw subject with one that has
    /// Luna's subject prefix already stripped, so the saved title never
    /// carries it.
    private func importFromBody(
        _ message: FetchedMessage, subjectOverride: String?, contact: Friend?
    ) {
        let incoming = IncomingMessage(
            uid: message.uid ?? 0, from: message.from, subject: subjectOverride ?? message.subject,
            date: message.date, contentType: message.headers["content-type"] ?? "",
            transferEncoding: message.headers["content-transfer-encoding"] ?? "",
            body: message.bodyText, urls: Self.urls(in: message.bodyText))

        if let content = MailArticleBuilder.article(from: incoming) {
            let item = store.add(urlString: "lunamail://\(message.id)", source: .email)
            recordSender(message, contact: contact, itemID: item.id)
            let ready = store.saveContent(content, for: item)
            // Article-kind hook for Kindle/ereader auto-send. A no-op in apps
            // without article handling — they have no send destination.
            if ready.state == .ready { SaveReadiness.observer?.saveBecameReady(ready) }
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
