//
//  ArticleSendCoordinator.swift
//  Luna
//

import LunaEpub
import LunaStorage
import LunaModels
import LunaMailAccount
import LunaAppConfig
import Foundation
import os

/// One destination an article can be delivered to.
/// The coordinator's gating/state logic is destination-agnostic; each
/// destination just knows whether it's configured, when it auto-sends, and how
/// to deliver an EPUB.
public protocol ArticleDestination {
    /// Stable id (see `ArticleDestinationID`), used as the per-item state key.
    var id: String { get }
    /// User-facing name.
    var displayName: String { get }
    /// Whether sends can actually go out (credentials/config present).
    var isConfigured: Bool { get }
    /// The auto-send mode for an item, resolved from its capture source (email,
    /// App Intents, share sheet, friend shares, …).
    func sendMode(for item: SavedItem) -> ArticleSendMode
    /// The mode governing App Intents / in-app saves — the only source whose
    /// "double save" press is detected at save time.
    var appIntentsSendMode: ArticleSendMode { get }
    /// Delivers the EPUB. Throws on any configuration/connection/service failure.
    func send(epubData: Data, fileName: String, title: String) async throws
}

/// Supplies the `EmailTransport` for the connected account. LunaSend sits below
/// LunaMailTransport (which builds the transport), so the conformer lives up
/// there and the app installs it at launch.
public protocol EmailTransportProviding {
    /// The transport for the connected account, or nil when no account can send.
    func makeTransport() -> EmailTransport?
}

/// Where that provider is installed. It stays nil in contexts that never send
/// (extensions), meaning email sends fail as not-configured until the app runs.
public enum ArticleEmailTransportProvider {
    public static var installed: (any EmailTransportProviding)?
}

/// Builds the article's MIME message and hands it to the connected email
/// account's transport.
public final class AccountEmailSender {

    public struct NotConfiguredError: Error {}

    public init() {}

    public func sendArticle(epubData: Data, fileName: String, title: String) async throws {
        guard let account = EmailAccountStore.shared.account,
              let transport = ArticleEmailTransportProvider.installed?.makeTransport()
        else { throw NotConfiguredError() }

        let message = MIMEMessage(
            from: account.address,
            to: KindleSendSettings.kindleAddress,
            subject: title,
            bodyText: "Sent to Kindle by Luna.",
            attachmentFileName: fileName,
            attachmentMimeType: "application/epub+zip",
            attachmentData: epubData)

        try await transport.send(OutgoingEmail(
            recipients: [KindleSendSettings.kindleAddress],
            subject: title,
            rawMIME: message.messageData()))
    }
}

/// The Kindle destination: email through the connected Luna account.
public final class KindleDestination: ArticleDestination {
    public let id = ArticleDestinationID.kindle
    public let displayName = L10n.string("Common_kindle")

    private let sender = AccountEmailSender()

    public init() {}

    public var isConfigured: Bool { KindleSendSettings.isConfigured }

    public func sendMode(for item: SavedItem) -> ArticleSendMode {
        SourceSendSettings.sendMode(
            forDestination: id, source: item.effectiveCaptureSource,
            friendUsername: item.sharedByUsername)
    }

    public var appIntentsSendMode: ArticleSendMode { SourceSendSettings.appIntentsMode(forDestination: id) }

    public func send(epubData: Data, fileName: String, title: String) async throws {
        try await sender.sendArticle(epubData: epubData, fileName: fileName, title: title)
    }
}

/// Receives each detached delivery task the coordinator starts, so a test can
/// await the work instead of sleeping. Nothing in the apps conforms.
@_spi(Testing)
public protocol ArticleDeliveryTaskObserving: AnyObject {
    func coordinatorDidStartDeliveryTask(_ task: Task<Void, Never>)
}

/// Orchestrates ereader sends across destinations: gating, queueing while an
/// article is still ingesting, EPUB generation, delivery, and per-destination
/// per-item state.
public final class ArticleSendCoordinator {

    public static let shared = ArticleSendCoordinator()

    public struct RetryPolicy {
        public let maxSoftFailures: Int
        public let initialDelay: TimeInterval
        public let maxDelay: TimeInterval

        public init(
            maxSoftFailures: Int = 5,
            initialDelay: TimeInterval = 15 * 60,
            maxDelay: TimeInterval = 12 * 60 * 60
        ) {
            self.maxSoftFailures = max(1, maxSoftFailures)
            self.initialDelay = initialDelay
            self.maxDelay = maxDelay
        }

        func delay(afterSoftFailureCount count: Int) -> TimeInterval {
            let exponent = max(0, count - 1)
            let multiplier = pow(2.0, Double(exponent))
            return min(maxDelay, initialDelay * multiplier)
        }
    }

    private let logger = Logger(subsystem: LunaLogging.subsystem, category: "send")
    private let store: SavesStore
    private let destinations: [ArticleDestination]
    private let retryPolicy: RetryPolicy
    private let now: () -> Date

    /// In-flight "<itemID>|<destinationID>" keys, to avoid duplicate concurrent
    /// deliveries of the same item to the same destination.
    private var inFlight = Set<String>()
    private let lock = NSLock()

    /// Testing seam. `articleBecameReady`/`retryPendingSends` are synchronous
    /// entry points that fan delivery out into detached `Task`s; with nothing
    /// to await, a test can only sleep and hope. When an observer is attached,
    /// every task they start is handed over so the test can await it instead.
    /// Nil in production — nothing is retained and no behavior changes.
    ///
    /// Weak: the observer is the test case, which owns the coordinator.
    @_spi(Testing)
    public weak var deliveryTaskObserver: (any ArticleDeliveryTaskObserving)?

    public init(
        store: SavesStore = .shared,
        destinations: [ArticleDestination]? = nil,
        retryPolicy: RetryPolicy = RetryPolicy(),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.destinations = destinations ?? [KindleDestination()]
        self.retryPolicy = retryPolicy
        self.now = now
    }

    private func destination(id: String) -> ArticleDestination? {
        destinations.first { $0.id == id }
    }

    /// Whether ANY destination is configured (gates the long-press menu / "is
    /// send available at all").
    public var isConfigured: Bool { destinations.contains { $0.isConfigured } }

    /// Whether a specific destination is configured (gates its menu row).
    public func isConfigured(destinationID: String) -> Bool {
        destination(id: destinationID)?.isConfigured ?? false
    }

    /// Configured destinations whose App Intents / in-app save mode is
    /// double-save (for `SavePressPolicy` — only active saves are double-pressed).
    public func doubleSaveDestinationIDs() -> [String] {
        destinations.filter { $0.isConfigured && $0.appIntentsSendMode == .doubleSave }.map(\.id)
    }

    /// Explicit send of one article to one destination (the long-press menu).
    /// No-op when that destination isn't configured.
    public func send(_ item: SavedItem, toDestinationID id: String) async {
        guard let destination = destination(id: id) else { return }
        await sendBuildingEPUB(item, to: destination, respectBackoff: false)
    }

    /// Called by the ingestor when an article becomes ready: per destination,
    /// delivers anything queued by an earlier press, plus everything when that
    /// destination's mode is "all saves".
    public func articleBecameReady(_ item: SavedItem) {
        guard !item.isPlatformItem else { return }
        for destination in destinations where destination.isConfigured {
            let state = item.sendState(for: destination.id)
            let shouldSend = state == .queued
                || (destination.sendMode(for: item) == .allSaves && state == nil)
            guard shouldSend else { continue }
            let task = Task { await self.sendBuildingEPUB(item, to: destination, respectBackoff: true) }
            deliveryTaskObserver?.coordinatorDidStartDeliveryTask(task)
        }
    }

    /// Retries queued sends whose backoff has elapsed across all destinations.
    public func retryPendingSends() {
        for item in store.items() {
            for destination in destinations where destination.isConfigured {
                let state = item.sendState(for: destination.id)
                guard state == .queued else { continue }
                guard shouldAttempt(item, destinationID: destination.id, respectBackoff: true) else {
                    continue
                }
                let task = Task { await self.sendBuildingEPUB(item, to: destination, respectBackoff: true) }
                deliveryTaskObserver?.coordinatorDidStartDeliveryTask(task)
            }
        }
    }

    // MARK: - Delivery

    /// Builds the EPUB (once) and delivers to one destination.
    private func sendBuildingEPUB(
        _ item: SavedItem, to destination: ArticleDestination, respectBackoff: Bool
    ) async {
        guard destination.isConfigured else { return }
        guard let fresh = store.item(withID: item.id) else { return }
        guard !fresh.isPlatformItem else { return } // platform items have no article EPUB
        guard shouldAttempt(fresh, destinationID: destination.id, respectBackoff: respectBackoff) else {
            return
        }

        guard fresh.state == .ready else {
            store.setSendState(.queued, for: fresh.id, destination: destination.id)
            return
        }
        // Fetch any images the article hasn't downloaded yet before building the
        // book — an auto-send fires the moment an article becomes ready, which
        // is BEFORE its pictures have finished arriving, and a Kindle EPUB with
        // no illustrations is the wrong book.
        await ArticleExportService(store: store).prepareImages(for: fresh)
        guard let refreshed = store.item(withID: fresh.id),
              let built = buildEPUB(for: refreshed) else {
            store.markSendTerminalFailure(
                for: fresh.id, destination: destination.id,
                errorMessage: "Couldn't build the EPUB attachment.")
            return
        }
        await deliver(itemID: fresh.id, built: built, to: destination)
    }

    private func shouldAttempt(
        _ item: SavedItem, destinationID: String, respectBackoff: Bool
    ) -> Bool {
        guard item.sendState(for: destinationID) != .failed else { return false }
        guard respectBackoff, let next = item.sendNextAttemptDates[destinationID] else {
            return true
        }
        return next <= now()
    }

    private struct BuiltEPUB {
        let data: Data
        let fileName: String
        let title: String
    }

    private func buildEPUB(for item: SavedItem) -> BuiltEPUB? {
        guard let content = store.content(for: item) else { return nil }
        let title = item.title ?? item.urlString
        let data = EpubBuilder().build(
            content: content, sourceURLString: item.urlString,
            imagesDirectory: store.articlesDirectory)
        return BuiltEPUB(data: data, fileName: Self.epubFileName(forTitle: title), title: title)
    }

    private func deliver(itemID: UUID, built: BuiltEPUB, to destination: ArticleDestination) async {
        let key = "\(itemID.uuidString)|\(destination.id)"
        let alreadySending = lock.withLock {
            let sending = inFlight.contains(key)
            if !sending { inFlight.insert(key) }
            return sending
        }
        guard !alreadySending else { return }
        defer { lock.withLock { _ = inFlight.remove(key) } }

        // Queued first: if the process dies mid-send, launch/background sweeps retry.
        store.markSendAttemptStarted(for: itemID, destination: destination.id)
        do {
            try await destination.send(
                epubData: built.data, fileName: built.fileName, title: built.title)
            store.setSendState(.sent, for: itemID, destination: destination.id)
            logger.info("Sent to \(destination.displayName, privacy: .public): \(built.title, privacy: .public)")
        } catch {
            recordFailure(error, itemID: itemID, built: built, destination: destination)
            logger.error("Send to \(destination.displayName, privacy: .public) failed for \(built.title, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func recordFailure(
        _ error: Error, itemID: UUID, built: BuiltEPUB, destination: ArticleDestination
    ) {
        let message = Self.userVisibleErrorMessage(error)
        guard !Self.isHardFailure(error),
              let item = store.item(withID: itemID)
        else {
            store.markSendTerminalFailure(
                for: itemID, destination: destination.id, errorMessage: message)
            return
        }

        let failureCount = (item.sendFailureCounts[destination.id] ?? 0) + 1
        guard failureCount < retryPolicy.maxSoftFailures else {
            store.markSendTerminalFailure(
                for: itemID, destination: destination.id,
                errorMessage: L10n.string("Reader_export_giveUpAfterAttemptsMessage", message, failureCount),
                failureCount: failureCount)
            return
        }

        let delay = retryPolicy.delay(afterSoftFailureCount: failureCount)
        let nextAttempt = now().addingTimeInterval(delay)
        store.scheduleSendRetry(
            for: itemID, destination: destination.id, failureCount: failureCount,
            nextAttemptDate: nextAttempt, errorMessage: message)
        logger.info("Scheduled retry \(failureCount, privacy: .public) for \(destination.displayName, privacy: .public) in \(delay, privacy: .public)s: \(built.title, privacy: .public)")
    }

    private static func isHardFailure(_ error: Error) -> Bool {
        if error is AccountEmailSender.NotConfiguredError { return true }
        let text = String(describing: error).lowercased()
        return text.contains("auth")
            || text.contains("not signed in")
            || text.contains("missing microsoft client id")
            || text.contains("token refresh failed")
            || text.contains("message missing sender or recipients")
            || text.contains("http 401")
            || text.contains("http 403")
            || text.contains("(401)")
            || text.contains("(403)")
    }

    private static func userVisibleErrorMessage(_ error: Error) -> String {
        let message = String(describing: error)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? L10n.string("Reader_export_deliveryFailedMessage") : message
    }

    /// Sends a minimal test document to one destination so the user can verify
    /// their setup end to end.
    public func sendTestDocument(toDestinationID id: String) async throws {
        guard let destination = destination(id: id) else { return }
        let content = ArticleContent(
            title: L10n.string("Reader_export_testDocumentTitle"),
            blocks: [ArticleContent.Block(
                kind: .paragraph,
                text: L10n.string("Reader_export_testDocumentBody"),
                links: [])])
        let epub = EpubBuilder().build(
            content: content,
            sourceURLString: "https://luna.local/test",
            imagesDirectory: store.articlesDirectory)
        try await destination.send(
            epubData: epub,
            fileName: L10n.string("Reader_export_testDocumentFileName"),
            title: content.title)
    }

    /// A filesystem- and MIME-safe attachment name derived from the title.
    public static func epubFileName(forTitle title: String) -> String {
        fileName(forTitle: title, extension: ArticleExportFormat.epub.fileExtension)
    }

    /// A filesystem- and MIME-safe file name derived from the title, with the
    /// given extension — the one sanitizer behind both the emailed EPUB
    /// attachment and every share-sheet export format.
    public static func fileName(forTitle title: String, extension fileExtension: String) -> String {
        let disallowed = CharacterSet(charactersIn: "/\\:?%*|\"<>\r\n")
        let cleaned = title.components(separatedBy: disallowed).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Article" : String(cleaned.prefix(80))
        return base + "." + fileExtension
    }
}
