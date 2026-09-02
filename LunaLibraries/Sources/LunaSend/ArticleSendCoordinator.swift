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
    /// The EPUB contract this destination accepts. The coordinator uses it both
    /// to decide whether image preparation is appropriate and to build the
    /// final bytes that reach the transport.
    var epubBuildProfile: EpubBuilder.Profile { get }
    /// Delivers the EPUB. Throws on any configuration/connection/service failure.
    func send(epubData: Data, fileName: String, title: String) async throws
    /// Delivers the EPUB with the save's identity and queue depth attached.
    /// Destinations that report progress on a receiving device (Xteink's
    /// "book i of n") override this; everything else keeps the plain form.
    func send(epubData: Data, fileName: String, title: String, context: ArticleSendContext) async throws
    /// True for a destination whose receiver files a delivered save away by
    /// itself once it is read there. `ReadStateSendReconciler` drops a still
    /// -queued send whose save was finished in Luna first, so the receiver
    /// never gets a book its owner already considers done.
    var dequeuesOnRead: Bool { get }
    /// True for a destination whose share row is drawn from somewhere else —
    /// a plugin destination's row carries its declaration's title, symbol and
    /// status dot, none of which a `DestinationDescriptor` holds.
    var providesOwnShareRow: Bool { get }
    /// Delivers the SAVE. This is what the coordinator calls; the default
    /// builds the EPUB the two Swift destinations take, so a destination that
    /// accepts another format (a plugin destination declaring `url` or `json`)
    /// overrides it and never sees EPUB bytes it would discard.
    func deliver(item: SavedItem, context: ArticleSendContext) async throws
}

/// A destination throws an error conforming to this when the failure is
/// TERMINAL: another attempt cannot change the answer, so the coordinator marks
/// the send failed rather than scheduling backoff. Conforming is the signal; an
/// error that is terminal only sometimes answers `isHardSendFailure` itself.
public protocol SendHardFailureError: Error {
    var isHardSendFailure: Bool { get }
}

public extension SendHardFailureError {
    var isHardSendFailure: Bool { true }
}

/// Why a delivery could not be attempted at all. It is a HARD failure: an
/// article with no readable content will not gain any on a retry.
public enum ArticleDeliveryError: Error, CustomStringConvertible, SendHardFailureError {
    case noArticleContent

    public var description: String {
        switch self {
        case .noArticleContent: return "Couldn't build the EPUB attachment."
        }
    }
}

public extension ArticleDestination {
    /// Existing third-party conformers remain standard EPUB destinations. The
    /// built-in Xteink id is text-only even while its transport is evolving;
    /// custom destinations can override this property explicitly.
    var epubBuildProfile: EpubBuilder.Profile {
        id == ArticleDestinationID.xteink ? .xteink : .standard
    }

    /// Destinations that don't track a receiving-device queue (Kindle,
    /// export) just ignore the context and keep their existing send.
    func send(epubData: Data, fileName: String, title: String, context: ArticleSendContext) async throws {
        try await send(epubData: epubData, fileName: fileName, title: title)
    }

    /// The two Swift destinations are drawn from their descriptor.
    var providesOwnShareRow: Bool { false }

    /// A destination keeps its queue regardless of read state unless it says
    /// otherwise: dropping a queued send is only right for a receiver that
    /// tracks reading of its own.
    var dequeuesOnRead: Bool { false }

    /// An EPUB destination: fetch the article's missing images when this
    /// destination's profile carries images, build the book, hand it over.
    /// Reads the store the coordinator is reading, so a coordinator driving a
    /// scratch store stays inside it.
    func deliver(item: SavedItem, context: ArticleSendContext) async throws {
        let store = context.store
        if epubBuildProfile.includesImages {
            await ArticleExportService(store: store).prepareImages(for: item)
        }
        let fresh = store.item(withID: item.id) ?? item
        guard let content = store.content(for: fresh) else {
            throw ArticleDeliveryError.noArticleContent
        }
        let title = fresh.title ?? fresh.urlString
        let data = EpubBuilder().build(
            content: content, sourceURLString: fresh.urlString,
            imagesDirectory: store.articlesDirectory, profile: epubBuildProfile)
        try await send(
            epubData: data, fileName: ArticleSendCoordinator.epubFileName(forTitle: title),
            title: title, context: context)
    }
}

/// The destinations a higher tier installs at launch: one per export plugin
/// that declares itself a destination (`claudedocs/plans/plugin-platform.md`
/// §9.4).
///
/// It is a registry rather than an `init` argument because the plugin platform
/// is built after `ArticleSendCoordinator.shared` may already exist, and
/// because a plugin that REPLACES a Swift destination must retire it by id —
/// the Kindle plugin keeps the `kindle` id, so every stored send state,
/// per-source setting and sent date keeps applying to it.
public enum ArticleDestinationRegistry {

    private static let lock = NSLock()
    private static var destinations: [any ArticleDestination] = []
    private static var replacedIDs: Set<String> = []

    /// Replaces what an earlier call installed. Idempotent, so a second
    /// platform install leaves one set of destinations rather than two.
    public static func install(
        _ destinations: [any ArticleDestination], replacingBuiltInIDs ids: Set<String>
    ) {
        lock.lock()
        self.destinations = destinations
        replacedIDs = ids
        lock.unlock()
    }

    public static var installed: [any ArticleDestination] {
        lock.lock()
        defer { lock.unlock() }
        return destinations
    }

    /// Built-in destination ids a plugin now owns. The coordinator drops those
    /// Swift destinations, so one id never has two delivery routes.
    public static var replacedBuiltInIDs: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return replacedIDs
    }

    /// Empties the registry. Tests use it to leave the process as they found it.
    public static func removeAll() {
        install([], replacingBuiltInIDs: [])
    }
}

/// The save identity and queue depth a delivery carries, for a destination
/// that reports progress on its receiving device. `queuedRemaining` is the
/// count of OTHER items still `.queued` for the same destination at the
/// moment this one is handed to `send` — the coordinator's sweep is serial,
/// so this decrements naturally as the queue drains.
public struct ArticleSendContext {
    public let itemID: UUID
    public let queuedRemaining: Int?
    /// The store this delivery reads. `deliver`'s default implementation
    /// builds the EPUB from it, so a coordinator driving a scratch store never
    /// reaches the shared one.
    public let store: SavesStore
    public init(itemID: UUID, queuedRemaining: Int?, store: SavesStore = .shared) {
        self.itemID = itemID
        self.queuedRemaining = queuedRemaining
        self.store = store
    }
}

/// A destination throws an error conforming to this when its receiver simply
/// isn't reachable right now — the Xteink only serves while awake on its
/// transfer screen, so absence is the normal state, not a delivery failure.
/// The coordinator keeps the item queued without spending a soft-failure
/// retry or scheduling backoff; the next sweep (launch, foreground,
/// background, Wi-Fi available, mail BGTask) tries again.
public protocol SendDeferralError: Error {}

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
    private let builtInDestinations: [ArticleDestination]
    /// True for the shipped coordinator, which serves whatever the plugin
    /// platform installed as well as the two Swift destinations. A caller that
    /// named its destinations gets exactly those.
    private let readsDestinationRegistry: Bool
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
        builtInDestinations = destinations ?? [KindleDestination(), XteinkDestination()]
        readsDestinationRegistry = destinations == nil
        self.retryPolicy = retryPolicy
        self.now = now
    }

    /// Every destination this coordinator serves right now. Read per use: a
    /// plugin destination arrives when the plugin platform is installed, which
    /// can be after `shared` was first touched.
    private var destinations: [ArticleDestination] {
        guard readsDestinationRegistry else { return builtInDestinations }
        let replaced = ArticleDestinationRegistry.replacedBuiltInIDs
        return builtInDestinations.filter { !replaced.contains($0.id) }
            + ArticleDestinationRegistry.installed
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

    /// A configured destination, as the share menu presents it.
    public struct DestinationDescriptor {
        public let id: String
        public let displayName: String
    }

    /// The configured destinations the share menu draws its own rows for. A
    /// destination that provides its own row is left out here, so the menu
    /// cannot offer the same destination twice.
    public func configuredDestinations() -> [DestinationDescriptor] {
        destinations.filter { $0.isConfigured && !$0.providesOwnShareRow }.map {
            DestinationDescriptor(id: $0.id, displayName: $0.displayName)
        }
    }

    /// Configured destinations whose App Intents / in-app save mode is
    /// double-save (for `SavePressPolicy` — only active saves are double-pressed).
    public func doubleSaveDestinationIDs() -> [String] {
        destinations.filter { $0.isConfigured && $0.appIntentsSendMode == .doubleSave }.map(\.id)
    }

    /// The destinations whose queue `ReadStateSendReconciler` prunes when a
    /// save is finished before its send goes out.
    public func dequeueOnReadDestinationIDs() -> [String] {
        destinations.filter(\.dequeuesOnRead).map(\.id)
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
            let shouldAutoSend = destination.sendMode(for: item) == .allSaves && state == nil
            let shouldSend = state == .queued || shouldAutoSend
            guard shouldSend else { continue }
            // Persist the automatic enqueue before handing work to a detached
            // task. This is both the durable intent and the hand-off that a
            // later Xteink rendezvous sweep consumes if the receiver is asleep.
            if shouldAutoSend {
                store.setSendState(.queued, for: item.id, destination: destination.id)
            }
            let task = Task { _ = await self.sendBuildingEPUB(item, to: destination, respectBackoff: true) }
            deliveryTaskObserver?.coordinatorDidStartDeliveryTask(task)
        }
    }

    /// Delivers every still-queued send for one destination, one at a time,
    /// and returns when the queue is drained — the Xteink rendezvous sweep's
    /// entry point. Backoff dates are ignored: backoff exists to stop
    /// unattended sweeps from hammering an unreachable receiver, and this
    /// runs only while the receiving device holds a live window open.
    /// (Terminal `.failed` items are not `.queued` and stay untouched.)
    public func deliverQueuedSends(toDestinationID id: String) async {
        guard let destination = destination(id: id), destination.isConfigured else { return }
        // A save finished before its window opened is dropped here rather
        // than delivered, so a plugin driving its own sweep through
        // `luna.exports.deliverQueued()` gets the same pre-pass the Swift
        // rendezvous sweep has.
        if destination.dequeuesOnRead {
            ReadStateSendReconciler.dequeueSendsFinishedBeforeDelivery(
                destinationIDs: [id], store: store)
        }
        let queued = store.items().filter { $0.sendState(for: id) == .queued }
        guard !queued.isEmpty else { return }
        SharedDiagnosticLog.record(
            "Rendezvous sweep: delivering \(queued.count) queued send(s)", category: "xteink")
        for (index, item) in queued.enumerated() {
            let error = await sendBuildingEPUB(item, to: destination, respectBackoff: false)
            // The reader's low_memory refusal is a device condition, not a
            // per-book one: every remaining start_put this window would be
            // refused the same way. Leave the rest queued for the next window.
            if case XteinkSyncError.protocolError("low_memory")? = error {
                SharedDiagnosticLog.record(
                    "Reader refused start_put: low memory; leaving \(queued.count - index - 1) queued send(s) for the next window",
                    category: "xteink")
                break
            }
        }
    }

    /// Retries queued sends whose backoff has elapsed across all destinations.
    public func retryPendingSends() {
        for item in store.items() {
            for destination in destinations where destination.isConfigured {
                // Share/action extensions persist article content directly and
                // cannot install ArticleShellWiring's readiness observer. On
                // launch/foreground the ready row is therefore the only signal
                // that an all-saves source needs an automatic send. Reconcile
                // that missing queue row before sweeping existing work.
                guard let current = store.item(withID: item.id) else { continue }
                if current.state == .ready,
                   current.sendState(for: destination.id) == nil,
                   destination.sendMode(for: current) == .allSaves {
                    store.setSendState(.queued, for: current.id, destination: destination.id)
                }

                guard let queued = store.item(withID: item.id),
                      queued.sendState(for: destination.id) == .queued else { continue }
                guard shouldAttempt(queued, destinationID: destination.id, respectBackoff: true) else {
                    continue
                }
                let task = Task { _ = await self.sendBuildingEPUB(queued, to: destination, respectBackoff: true) }
                deliveryTaskObserver?.coordinatorDidStartDeliveryTask(task)
            }
        }
    }

    // MARK: - Delivery

    /// Gates one send and hands the save to the destination. Returns the
    /// transport error when the send itself failed, nil when it succeeded or
    /// was not attempted — the rendezvous sweep reads it to recognize a
    /// device-wide refusal.
    ///
    /// The payload is the DESTINATION's business: `deliver` builds the EPUB for
    /// the two Swift destinations and produces its declared format for a plugin
    /// one.
    @discardableResult
    private func sendBuildingEPUB(
        _ item: SavedItem, to destination: ArticleDestination, respectBackoff: Bool
    ) async -> Error? {
        guard destination.isConfigured else { return nil }
        guard let fresh = store.item(withID: item.id) else { return nil }
        guard !fresh.isPlatformItem else { return nil } // platform items have no article EPUB
        guard shouldAttempt(fresh, destinationID: destination.id, respectBackoff: respectBackoff) else {
            return nil
        }

        guard fresh.state == .ready else {
            store.setSendState(.queued, for: fresh.id, destination: destination.id)
            return nil
        }
        return await deliver(item: fresh, to: destination)
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

    /// Returns the error the transport threw, nil on success or when this
    /// item's send is already in flight.
    private func deliver(item: SavedItem, to destination: ArticleDestination) async -> Error? {
        let itemID = item.id
        let title = item.title ?? item.urlString
        let key = "\(itemID.uuidString)|\(destination.id)"
        let alreadySending = lock.withLock {
            let sending = inFlight.contains(key)
            if !sending { inFlight.insert(key) }
            return sending
        }
        guard !alreadySending else { return nil }
        defer { lock.withLock { _ = inFlight.remove(key) } }

        // Queued first: if the process dies mid-send, launch/background sweeps retry.
        store.markSendAttemptStarted(for: itemID, destination: destination.id)
        do {
            let queuedRemaining = store.items().filter {
                $0.id != itemID && $0.sendState(for: destination.id) == .queued
            }.count
            try await destination.deliver(
                item: item,
                context: ArticleSendContext(
                    itemID: itemID, queuedRemaining: queuedRemaining, store: store))
            store.setSendState(.sent, for: itemID, destination: destination.id)
            logger.info("Sent to \(destination.displayName, privacy: .public): \(title, privacy: .public)")
        } catch {
            recordFailure(error, itemID: itemID, title: title, destination: destination)
            if error is SendDeferralError {
                logger.info("Deferred send to \(destination.displayName, privacy: .public) (unreachable): \(title, privacy: .public)")
            } else {
                logger.error("Send to \(destination.displayName, privacy: .public) failed for \(title, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            return error
        }
        return nil
    }

    private func recordFailure(
        _ error: Error, itemID: UUID, title: String, destination: ArticleDestination
    ) {
        // Deferral: the receiver is just not reachable right now.
        // `markSendAttemptStarted` already left the state `.queued`, so the
        // next sweep retries at full strength — no failure count, no backoff.
        if error is SendDeferralError { return }
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
        logger.info("Scheduled retry \(failureCount, privacy: .public) for \(destination.displayName, privacy: .public) in \(delay, privacy: .public)s: \(title, privacy: .public)")
    }

    private static func isHardFailure(_ error: Error) -> Bool {
        if error is AccountEmailSender.NotConfiguredError { return true }
        if let terminal = error as? (any SendHardFailureError), terminal.isHardSendFailure {
            return true
        }
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
            imagesDirectory: store.articlesDirectory,
            profile: destination.epubBuildProfile)
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
