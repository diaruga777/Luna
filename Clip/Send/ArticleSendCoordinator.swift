//
//  ArticleSendCoordinator.swift
//  Clip
//

import Foundation
import os

/// Stable destination ids, used as keys in `ReadingListItem.sendStates` and to
/// target explicit sends.
enum ArticleDestinationID {
    static let kindle = "kindle"
    static let boox = "boox"
}

/// One ereader an article can be delivered to (Kindle email, Boox cloud, …).
/// The coordinator's gating/state logic is destination-agnostic; each
/// destination just knows whether it's configured, when it auto-sends, and how
/// to deliver an EPUB.
protocol ArticleDestination {
    /// Stable id (see `ArticleDestinationID`), used as the per-item state key.
    var id: String { get }
    /// User-facing name ("Kindle", "Boox").
    var displayName: String { get }
    /// Whether sends can actually go out (credentials/config present).
    var isConfigured: Bool { get }
    /// When this destination auto-sends.
    var sendMode: ArticleSendMode { get }
    /// Delivers the EPUB. Throws on any configuration/connection/service failure.
    func send(epubData: Data, fileName: String, title: String) async throws
}

/// Emails an article's EPUB to the configured Kindle address.
protocol ArticleEmailSending {
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
            bodyText: "Sent to Kindle by Click.",
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

/// The Kindle destination: SMTP email.
final class KindleDestination: ArticleDestination {
    let id = ArticleDestinationID.kindle
    let displayName = "Kindle"

    private let credentials: SendCredentialsStoring
    private let sender: ArticleEmailSending

    init(credentials: SendCredentialsStoring = KeychainSendCredentialsStore.shared,
         sender: ArticleEmailSending? = nil) {
        self.credentials = credentials
        self.sender = sender ?? SMTPArticleEmailSender(credentials: credentials)
    }

    var isConfigured: Bool { KindleSendSettings.isConfigured(credentials: credentials) }
    var sendMode: ArticleSendMode { KindleSendSettings.sendMode }

    func send(epubData: Data, fileName: String, title: String) async throws {
        try await sender.sendArticle(epubData: epubData, fileName: fileName, title: title)
    }
}

/// Orchestrates ereader sends across destinations: gating, queueing while an
/// article is still ingesting, EPUB generation, delivery, and per-destination
/// per-item state.
final class ArticleSendCoordinator {

    static let shared = ArticleSendCoordinator()

    private let logger = Logger(subsystem: "com.hpiddy.clip", category: "send")
    private let store: ReadingListStore
    private let destinations: [ArticleDestination]

    /// In-flight "<itemID>|<destinationID>" keys, to avoid duplicate concurrent
    /// deliveries of the same item to the same destination.
    private var inFlight = Set<String>()
    private let lock = NSLock()

    init(store: ReadingListStore = .shared, destinations: [ArticleDestination]? = nil) {
        self.store = store
        self.destinations = destinations ?? [KindleDestination(), BooxDestination()]
    }

    private func destination(id: String) -> ArticleDestination? {
        destinations.first { $0.id == id }
    }

    /// Whether ANY destination is configured (gates the long-press menu / "is
    /// send available at all").
    var isConfigured: Bool { destinations.contains { $0.isConfigured } }

    /// Whether a specific destination is configured (gates its menu row).
    func isConfigured(destinationID: String) -> Bool {
        destination(id: destinationID)?.isConfigured ?? false
    }

    /// Configured destinations currently in double-save mode (for `SavePressPolicy`).
    func doubleSaveDestinationIDs() -> [String] {
        destinations.filter { $0.isConfigured && $0.sendMode == .doubleSave }.map(\.id)
    }

    /// Explicit send of one article to one destination (the long-press menu).
    /// No-op when that destination isn't configured.
    func send(_ item: ReadingListItem, toDestinationID id: String) async {
        guard let destination = destination(id: id) else { return }
        await sendBuildingEPUB(item, to: destination)
    }

    /// Called by the ingestor when an article becomes ready: per destination,
    /// delivers anything queued by an earlier press, plus everything when that
    /// destination's mode is "all saves".
    func articleBecameReady(_ item: ReadingListItem) {
        guard !item.isPlatformItem else { return }
        for destination in destinations where destination.isConfigured {
            let state = item.sendState(for: destination.id)
            let shouldSend = state == .queued
                || (destination.sendMode == .allSaves && state == nil)
            guard shouldSend else { continue }
            Task { await self.sendBuildingEPUB(item, to: destination) }
        }
    }

    /// Retries queued/failed sends across all destinations (pull-to-refresh).
    func retryPendingSends() {
        for item in store.items() {
            for destination in destinations where destination.isConfigured {
                let state = item.sendState(for: destination.id)
                guard state == .queued || state == .failed else { continue }
                Task { await self.sendBuildingEPUB(item, to: destination) }
            }
        }
    }

    // MARK: - Delivery

    /// Builds the EPUB (once) and delivers to one destination.
    private func sendBuildingEPUB(_ item: ReadingListItem, to destination: ArticleDestination) async {
        guard destination.isConfigured else { return }
        guard let fresh = store.item(withID: item.id) else { return }
        guard !fresh.isPlatformItem else { return } // platform items have no article EPUB

        guard fresh.state == .ready else {
            store.setSendState(.queued, for: fresh.id, destination: destination.id)
            return
        }
        guard let built = buildEPUB(for: fresh) else {
            store.setSendState(.failed, for: fresh.id, destination: destination.id)
            return
        }
        await deliver(itemID: fresh.id, built: built, to: destination)
    }

    private struct BuiltEPUB {
        let data: Data
        let fileName: String
        let title: String
    }

    private func buildEPUB(for item: ReadingListItem) -> BuiltEPUB? {
        guard let content = store.content(for: item) else { return nil }
        let title = item.title ?? item.urlString
        let data = EpubBuilder().build(
            content: content, sourceURLString: item.urlString,
            imagesDirectory: store.articlesDirectory)
        return BuiltEPUB(data: data, fileName: Self.epubFileName(forTitle: title), title: title)
    }

    private func deliver(itemID: UUID, built: BuiltEPUB, to destination: ArticleDestination) async {
        let key = "\(itemID.uuidString)|\(destination.id)"
        lock.lock()
        let alreadySending = inFlight.contains(key)
        if !alreadySending { inFlight.insert(key) }
        lock.unlock()
        guard !alreadySending else { return }
        defer {
            lock.lock()
            inFlight.remove(key)
            lock.unlock()
        }

        // Queued first: if the process dies mid-send, pull-to-refresh retries.
        store.setSendState(.queued, for: itemID, destination: destination.id)
        do {
            try await destination.send(
                epubData: built.data, fileName: built.fileName, title: built.title)
            store.setSendState(.sent, for: itemID, destination: destination.id)
            logger.info("Sent to \(destination.displayName, privacy: .public): \(built.title, privacy: .public)")
        } catch {
            store.setSendState(.failed, for: itemID, destination: destination.id)
            logger.error("Send to \(destination.displayName, privacy: .public) failed for \(built.title, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Sends a minimal test document to one destination so the user can verify
    /// their setup end to end.
    func sendTestDocument(toDestinationID id: String) async throws {
        guard let destination = destination(id: id) else { return }
        let content = ArticleContent(
            title: "Click Test Document",
            blocks: [ArticleContent.Block(
                kind: .paragraph,
                text: "If you can read this on your ereader, Click's send setup works.",
                links: [])])
        let epub = EpubBuilder().build(
            content: content,
            sourceURLString: "https://clip.local/test",
            imagesDirectory: store.articlesDirectory)
        try await destination.send(
            epubData: epub, fileName: "Click Test Document.epub", title: content.title)
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
