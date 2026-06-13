//
//  ArticleSendCoordinator.swift
//  Clip
//

import Foundation
import os

/// Sends one rendered article by email; abstracted so the coordinator's gating
/// and state transitions are testable without a network.
protocol ArticleEmailSending {
    /// Emails the EPUB to the configured Kindle address. Throws on any
    /// configuration, connection, or SMTP failure.
    func sendArticle(epubData: Data, fileName: String, title: String) async throws
}

/// Production sender: MIME message over implicit-TLS SMTP using the settings
/// and Keychain credentials.
final class SMTPArticleEmailSender: ArticleEmailSending {

    struct NotConfiguredError: Error {}

    private let credentials: SendCredentialsStoring

    init(credentials: SendCredentialsStoring = KeychainSendCredentialsStore.shared) {
        self.credentials = credentials
    }

    func sendArticle(epubData: Data, fileName: String, title: String) async throws {
        guard let password = credentials.smtpPassword(),
              KindleSendSettings.isConfigured(credentials: credentials)
        else { throw NotConfiguredError() }

        let message = MIMEMessage(
            from: KindleSendSettings.smtpUsername,
            to: KindleSendSettings.kindleAddress,
            subject: title,
            bodyText: "Sent to Kindle by Clip.",
            attachmentFileName: fileName,
            attachmentMimeType: "application/epub+zip",
            attachmentData: epubData)

        let transport = TLSConnectionTransport(
            host: KindleSendSettings.smtpHost, port: KindleSendSettings.port)
        let client = SMTPClient(transport: transport)
        try await client.submit(
            message: message,
            username: KindleSendSettings.smtpUsername,
            password: password)
    }
}

/// Orchestrates send-to-Kindle: gating, queueing while an article is still
/// ingesting, EPUB generation, delivery, and per-item send state.
final class ArticleSendCoordinator {

    static let shared = ArticleSendCoordinator()

    private let logger = Logger(subsystem: "com.hpiddy.clip", category: "send")
    private let store: ReadingListStore
    private let credentials: SendCredentialsStoring
    private let sender: ArticleEmailSending

    /// Items currently being sent, to avoid duplicate concurrent deliveries.
    private var inFlight = Set<UUID>()
    private let lock = NSLock()

    init(store: ReadingListStore = .shared,
         credentials: SendCredentialsStoring = KeychainSendCredentialsStore.shared,
         sender: ArticleEmailSending? = nil) {
        self.store = store
        self.credentials = credentials
        self.sender = sender ?? SMTPArticleEmailSender(credentials: credentials)
    }

    /// Whether sends can actually go out (address + SMTP account + password).
    var isConfigured: Bool {
        KindleSendSettings.isConfigured(credentials: credentials)
    }

    /// Sends an article to Kindle, queueing it instead if its content isn't
    /// ready yet (the ingestor re-fires queued items when ingestion finishes).
    /// No-op when not configured.
    func send(_ item: ReadingListItem) async {
        guard isConfigured else { return }
        guard let fresh = store.item(withID: item.id) else { return }
        // Videos have no article content to send to a Kindle.
        guard !fresh.isYouTubeVideo else { return }

        guard fresh.state == .ready else {
            store.setSendState(.queued, for: fresh.id)
            return
        }

        lock.lock()
        let alreadySending = inFlight.contains(fresh.id)
        if !alreadySending { inFlight.insert(fresh.id) }
        lock.unlock()
        guard !alreadySending else { return }
        defer {
            lock.lock()
            inFlight.remove(fresh.id)
            lock.unlock()
        }

        guard let content = store.content(for: fresh) else {
            store.setSendState(.failed, for: fresh.id)
            return
        }

        // Queued first: if the process dies mid-send, pull-to-refresh retries.
        store.setSendState(.queued, for: fresh.id)
        let title = fresh.title ?? fresh.urlString
        let epub = EpubBuilder().build(
            content: content,
            sourceURLString: fresh.urlString,
            imagesDirectory: store.articlesDirectory)

        do {
            try await sender.sendArticle(
                epubData: epub,
                fileName: Self.epubFileName(forTitle: title),
                title: title)
            store.setSendState(.sent, for: fresh.id)
            logger.info("Sent to Kindle: \(title, privacy: .public)")
        } catch {
            store.setSendState(.failed, for: fresh.id)
            logger.error("Send failed for \(title, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Called by the ingestor when an article becomes ready: delivers anything
    /// queued by an earlier press, and everything when the mode is "all saves".
    func articleBecameReady(_ item: ReadingListItem) {
        guard !item.isYouTubeVideo else { return }
        let shouldSend = item.sendState == .queued
            || (KindleSendSettings.sendMode == .allSaves && item.sendState == nil)
        guard shouldSend, isConfigured else { return }
        Task { await self.send(item) }
    }

    /// Retries queued/failed sends (pull-to-refresh).
    func retryPendingSends() {
        guard isConfigured else { return }
        for item in store.items() where item.sendState == .queued || item.sendState == .failed {
            Task { await self.send(item) }
        }
    }

    /// Sends a minimal test document so the user can verify their SMTP setup
    /// and approved-sender configuration end to end.
    func sendTestDocument() async throws {
        let content = ArticleContent(
            title: "Clip Test Document",
            blocks: [ArticleContent.Block(
                kind: .paragraph,
                text: "If you can read this on your Kindle, Clip's send-to-Kindle setup works.",
                links: [])])
        let epub = EpubBuilder().build(
            content: content,
            sourceURLString: "https://clip.local/test",
            imagesDirectory: store.articlesDirectory)
        try await sender.sendArticle(
            epubData: epub, fileName: "Clip Test Document.epub", title: content.title)
    }

    /// A filesystem- and MIME-safe attachment name derived from the title.
    static func epubFileName(forTitle title: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:?%*|\"<>\r\n")
        let cleaned = title.components(separatedBy: disallowed).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Article" : String(cleaned.prefix(80))
        return base + ".epub"
    }
}
