//
//  ReadingListIngestor.swift
//  Luna
//

import LunaStorage
import LunaIngest
import LunaFetch
import LunaHTMLClassification
import LunaURLClassification
import LunaModels
import LunaSocial
import Foundation

/// Downloads and extracts content for reading-list items: the immediate step
/// after a link is saved, plus a retry pass for anything still pending.
public final class ReadingListIngestor {
    public static let shared = ReadingListIngestor()

    private let store: ReadingListStore
    private let fetcher = ArticleFetcher()
    /// The per-app content gate over a classified outcome (`SurfaceSupport`).
    /// Injectable so tests can pin the running app without touching
    /// `Bundle.main`; the production default reads the running process's app.
    private let surfaceDecision: (Outcome) -> SurfaceSupport.Decision

    /// Presents the unsupported-kind error for a dropped INTERACTIVE in-app
    /// save (`.paste`/`.manual` sources only — App Intents get a dialog from
    /// the intent layer, background sweeps have no UI). Installed by the app
    /// shell at launch (AppDelegate), same injected-closure pattern as
    /// `PriceTrackingViewController.defaultSaveAsArticle` — LunaReadingList
    /// can't know how the app presents modals.
    public static var unsupportedSavePresenter: (@MainActor (_ owner: LunaApp) -> Void)?

    /// Installed by the app shell (`URLRescueWiring`) so a `.failed` first pass can
    /// hand the item to `URLRescueCoordinator`. nil in extensions / tests (rescue
    /// is main-app-only), where a failure just stays failed. Params: the item id,
    /// the resolved URL, the capture source, and whether this was an interactive
    /// (foreground, user-initiated) save.
    public static var rescueTrigger: ((UUID, URL, CaptureSource, _ interactive: Bool) -> Void)?

    public init(
        store: ReadingListStore = .shared,
        surfaceDecision: @escaping (Outcome) -> SurfaceSupport.Decision = {
            SurfaceSupport.evaluateForCurrentProcess(owner: $0.owningApp)
        }
    ) {
        self.store = store
        self.surfaceDecision = surfaceDecision
    }

    /// IDs currently being ingested, to avoid duplicate concurrent work.
    private var inFlight = Set<UUID>()
    private let lock = NSLock()

    /// Whether `id` is mid-ingest right now — the rescue sweep checks this to
    /// avoid racing an in-progress primary ingest.
    public func isIngesting(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight.contains(id)
    }

    /// Runs `ingestAllPending()`'s enumeration (a full `readingList.json` decode)
    /// and backfill scans off the caller's thread — it's called synchronously
    /// from launch, foreground, and pull-to-refresh, none of which should block
    /// on it.
    private let sweepQueue = DispatchQueue(
        label: "com.hsanabria.luna.readingListIngestor.sweep", qos: .utility)

    /// Fetches and extracts content for one item. Safe to call repeatedly.
    ///
    /// `forceArticle` skips product-page detection entirely, so the URL is ingested
    /// as a normal article even if its page would otherwise be classified as a price
    /// tracker. Used by the "Read instead" override on the price-tracking editor.
    ///
    /// The per-app content gate (`SurfaceSupport`) runs on the classified
    /// outcome before ANY store write: a foreign-kind save is discarded (item
    /// deleted, nothing remains) and the returned decision says so — for EVERY
    /// source, including `.email`/`.friendShare` (the owning app's own import
    /// picks the same message up when it's installed).
    /// `allowsInteractivePrompt` is false for the background `ingestAllPending`
    /// sweep, which discards dropped leftovers silently; interactive saves
    /// (`.paste`/`.manual`) surface the error via `unsupportedSavePresenter`.
    @discardableResult
    public func ingest(_ item: ReadingListItem, forceArticle: Bool = false,
                       prefetchedHTML: String? = nil,
                       trustsPrefetchedHTML: Bool = false,
                       allowsInteractivePrompt: Bool = true) async -> SurfaceSupport.Decision {
        guard item.state != .ready, let initialURL = item.url else { return .supported }

        lock.lock()
        let alreadyRunning = inFlight.contains(item.id)
        if !alreadyRunning { inFlight.insert(item.id) }
        lock.unlock()
        guard !alreadyRunning else { return .supported }
        defer {
            lock.lock()
            inFlight.remove(item.id)
            lock.unlock()
        }

        let url = initialURL

        // The ONE shared pipeline resolves wrappers, classifies, and processes every
        // URL. Its result carries the exact final URL, so this store is repointed
        // without independently repeating the unwrap work.
        let result = await IngestPipeline.processResolved(
            IngestInput(url: url, source: item.effectiveCaptureSource,
                        documentType: item.sanitizedDocumentType,
                        prefetchedHTML: prefetchedHTML, forceArticle: forceArticle,
                        trustsPrefetchedHTML: trustsPrefetchedHTML),
            fetcher: fetcher)

        let decision = await applyResult(
            result, for: item, forceArticle: forceArticle,
            allowsInteractivePrompt: allowsInteractivePrompt)

        // URL-Rescue hook: a genuine `.failed` first pass is the one place a
        // rescue may help. `itemJustFailed` re-reads the item from the store and
        // no-ops unless it's still `.failed` and rescue is eligible — so a
        // surface-dropped or already-existing item never triggers one. The rescue
        // engine re-enters the RAW pipeline (not this method), so it can't recurse.
        if case .failed = result.outcome {
            let interactive = allowsInteractivePrompt && isInteractivePromptSource(item.effectiveCaptureSource)
            Self.rescueTrigger?(item.id, result.url, item.effectiveCaptureSource, interactive)
        }
        return decision
    }

    /// Persists an `IngestResult` for `item` through the surface gate, URL
    /// repoint, tracker-merge dedup, and the outcome presenter — the shared tail
    /// of a first-pass ingest. `URLRescueCoordinator` also calls this to persist
    /// a rescued `IngestResult`, so a rescued item follows the exact same gate
    /// and presentation rules as any save. Returns the surface decision.
    @discardableResult
    func applyResult(
        _ result: IngestResult, for item: ReadingListItem, forceArticle: Bool,
        allowsInteractivePrompt: Bool
    ) async -> SurfaceSupport.Decision {
        var item = item
        let resolvedURL = result.url
        if let itemURL = item.url, resolvedURL != itemURL {
            SharedDiagnosticLog.record(
                "ingest: unwrapped \(itemURL.absoluteString) → \(resolvedURL.absoluteString)",
                category: "ingest")
            guard let updated = store.updateURL(resolvedURL.absoluteString, for: item.id) else {
                // The unwrapped article already exists in the list; wrapper dropped.
                return .supported
            }
            item = updated
        }

        // Per-app content gate — BEFORE the tracker-merge dedup below and before
        // the presenter, so a dropped outcome can neither merge into an existing
        // tracker nor write anything else. Every source is gated.
        let source = item.effectiveCaptureSource
        let decision = surfaceDecision(result.outcome)
        if case let .unsupported(owner) = decision {
            await presentUnsupportedSave(
                owner: owner, source: source,
                allowsInteractivePrompt: allowsInteractivePrompt,
                logMessage: "surface: dropped \(owner.storageIdentifier)-owned save — discarded",
                discard: { store.delete(item) })
            return decision
        }

        // Re-save dedup AFTER resolution: if this exact URL is already a store
        // inside an existing price tracker, it was already classified as
        // price-tracking on a previous save. The merge path deletes the placeholder,
        // so a re-save arrives as a fresh placeholder here.
        if !forceArticle,
           let (existingTrackerItemID, _) = store.priceTracker(
               containingStoreURL: resolvedURL.absoluteString),
           existingTrackerItemID != item.id {
            store.delete(item)
            PriceTrackerSaveAnnouncement.post(
                itemID: existingTrackerItemID, source: item.effectiveCaptureSource,
                isMerge: true, highlightedURL: resolvedURL.absoluteString)
            return decision
        }

        let presenter = IngestorOutcomePresenter(ingestor: self, url: resolvedURL)
        await presenter.present(result.outcome, for: item)
        return decision
    }

    /// Persists a rescued `IngestResult` for an existing item through the shared
    /// `applyResult` tail (surface gate + presenter), returning whether the item
    /// actually advanced (not surface-dropped). Called by `URLRescueCoordinator`'s
    /// app-shell bridge — the public seam over the internal `applyResult`.
    @discardableResult
    public func applyRescued(_ result: IngestResult, forItemID id: UUID, interactive: Bool) async -> Bool {
        guard let item = store.item(withID: id) else { return false }
        let forceArticle: Bool
        if case .article = result.outcome { forceArticle = true } else { forceArticle = false }
        let decision = await applyResult(
            result, for: item, forceArticle: forceArticle, allowsInteractivePrompt: interactive)
        if case .unsupported = decision { return false }
        return true
    }

    /// `.paste`/`.manual` are the only sources with a live UI able to show the
    /// unsupported-kind error — App Intents get their own dialog from the intent
    /// layer, and background sweeps have no UI at all.
    private func isInteractivePromptSource(_ source: CaptureSource) -> Bool {
        source == .paste || source == .manual
    }

    /// Logs and, if eligible, presents the unsupported-kind error for a
    /// surface-dropped save. `discard` runs first — `ingest` deletes the store
    /// placeholder it already created; `saveNewWithContent` calls this before ever
    /// adding one, so its `discard` is a no-op. Both call sites run this inline
    /// (never from a `defer`), so it can safely `await` the presenter.
    private func presentUnsupportedSave(
        owner: LunaApp, source: CaptureSource,
        allowsInteractivePrompt: Bool, logMessage: String, discard: () -> Void
    ) async {
        discard()
        SharedDiagnosticLog.record(logMessage, category: "ingest")
        guard allowsInteractivePrompt, isInteractivePromptSource(source) else { return }
        await MainActor.run {
            Self.unsupportedSavePresenter?(owner)
        }
    }

    // MARK: - Outcome handling (the main-app presenter, store-writing)

    /// Persists a readable article via the registered article handler.
    fileprivate func persistArticle(
        _ content: ArticleContent, html: String, for item: ReadingListItem, url: URL
    ) async {
        guard let handler = IngestorKindHandlers.article else {
            missingHandlerFallback(kind: "article", for: item)
            return
        }
        await handler.persistArticle(content, html: html, for: item, url: url, store: store)
    }

    /// Parks a paywalled article for the interactive archive reader.
    fileprivate func parkNeedsArchive(title: String, for item: ReadingListItem) async {
        store.markNeedsCaptcha(item.id, title: title)
    }

    /// Marks a genuine failure, and files WHY in the sidecar so the failed card
    /// can explain itself instead of showing one generic sentence.
    fileprivate func markFailed(for item: ReadingListItem, reason: SaveFailureReason? = nil) async {
        store.markFailed(item.id)
        SaveFailureStore.shared.recordFailure(item.id, reason: reason)
    }

    /// Ingests a document outcome via the registered article handler (documents
    /// are article-kind: they read in the article reader and are Kindle-eligible).
    fileprivate func handleDocument(type: String, for item: ReadingListItem) async {
        guard let handler = IngestorKindHandlers.article else {
            missingHandlerFallback(kind: "article (document)", for: item)
            return
        }
        await handler.ingestDocument(item, store: store)
    }

    /// Ingests a recognized video outcome via the registered media handler.
    fileprivate func handleVideo(
        _ platform: ContentPlatform, itemID: String?, for item: ReadingListItem
    ) async {
        await ingestPlatformItem(item, platform: platform, itemID: itemID)
    }

    /// Ingests a recognized social platform outcome (best-effort metadata).
    fileprivate func handlePlatform(
        _ platform: ContentPlatform, itemID: String?, for item: ReadingListItem
    ) async {
        await ingestPlatformItem(item, platform: platform, itemID: itemID)
    }

    /// Turns a detected product page into a price tracker via the registered
    /// product handler.
    fileprivate func ingestProductTracker(
        _ item: ReadingListItem, url: URL, product: ProductInfo
    ) async {
        guard let handler = IngestorKindHandlers.product else {
            missingHandlerFallback(kind: "product", for: item)
            return
        }
        await handler.ingestProductTracker(item, url: url, product: product, store: store)
    }

    /// Ingests a recognized platform item via the registered media handler.
    private func ingestPlatformItem(
        _ item: ReadingListItem, platform: ContentPlatform, itemID: String?
    ) async {
        guard let handler = IngestorKindHandlers.media else {
            missingHandlerFallback(kind: "media", for: item)
            return
        }
        await handler.ingestPlatformItem(
            item, platform: platform, platformItemID: itemID, store: store)
    }

    /// A kind reached the presenter without its handler registered. That's a
    /// programming error — the `SurfaceSupport` gate runs BEFORE presentation, so
    /// an app only ever presents kinds it declared, and its composition root
    /// (`KindWiring`) must have installed the matching handler. Fail loudly in
    /// debug; in release, mark the item failed rather than leaving it pending.
    private func missingHandlerFallback(kind: String, for item: ReadingListItem) {
        assertionFailure("no IngestorKindHandlers handler registered for \(kind)")
        SharedDiagnosticLog.record(
            "ingest: no \(kind) handler registered — marking \(item.id) failed",
            category: "ingest")
        store.markFailed(item.id)
        SaveFailureStore.shared.recordFailure(item.id, reason: .unknown)
    }

    /// Kicks off ingestion for everything not yet ready (app launch / foreground).
    /// The enumeration (`store.items()` decode) and the two backfill scans run off
    /// the caller's thread on `sweepQueue`; per-item ingestion was already async
    /// (`Task { await self.ingest(item) }`) and the backfills already hop to
    /// `@MainActor` internally for their own store reads, so this only changes
    /// which thread performs the initial decode + candidate scan.
    /// `completion` is a test seam: it fires once the sweep body (not the
    /// fire-and-forget per-item/backfill work it spawns) has run.
    public func ingestAllPending(completion: (() -> Void)? = nil) {
        sweepQueue.async {
            // `.needsCaptcha` items can only advance when the user solves the
            // archive CAPTCHA, so a background re-fetch can't help them — retry
            // only the states that an automated pass can actually move forward.
            // The sweep has no UI: blocked non-exempt leftovers are discarded
            // silently, while email/friend-share items remain exempt.
            for item in self.store.items() where item.state == .pending || item.state == .failed {
                Task { await self.ingest(item, allowsInteractivePrompt: false) }
            }
            self.backfillMissingWebArchives()
            self.backfillMissingThumbnails()
            completion?()
        }
    }

    /// Repairs ready and locked web articles that have no row thumbnail — the
    /// action/share extension persists article content WITHOUT fetching the page's
    /// cover image (it's short-lived and sandbox-limited), and locked rows can often
    /// still expose `og:image` before unlock. Delegates to the article handler
    /// (which owns the cover-fetch machinery and the per-session attempt state);
    /// a silent no-op in apps that don't handle articles, whose stores can't
    /// contain thumbnail-less article rows in the first place.
    public func backfillMissingThumbnails() {
        IngestorKindHandlers.article?.backfillMissingThumbnails(store: store)
    }

    /// `.webarchive` capture was added after many items were saved, and several save
    /// surfaces (extensions, paste, friend-share) don't capture inline. Delegates to
    /// the article handler (which owns the WebKit capture machinery and the
    /// per-session attempt state); a silent no-op in apps that don't handle articles.
    public func backfillMissingWebArchives() {
        IngestorKindHandlers.article?.backfillMissingWebArchives(store: store)
    }

    /// What a save press did, so intents can wait on the right work.
    public enum SavePressResult {
        /// New URL — saved; ingestion may still be running.
        case saved(ReadingListItem)
        /// New URL whose classified outcome belongs to a kind this app doesn't
        /// handle: the item was DISCARDED — nothing remains in the store.
        /// Interactive in-app saves have already shown the unsupported-kind
        /// error by the time this returns; the Save App Intent turns it into
        /// an error dialog.
        case unsupportedKind(owner: LunaApp)
        /// Double press — the article was (re)sent to one or more ereaders.
        case sentToEreaders(ReadingListItem)
        /// Double press — the article was emailed to the preset friends.
        case sentToFriends(ReadingListItem)
        /// Double press — the app should open its friend selector for the item
        /// (the pending prompt is already recorded; the intent's caller returns
        /// the open-Luna token so the Shortcut foregrounds the app).
        case friendPromptRequested(ReadingListItem)
        /// Duplicate press — nothing happened.
        case ignored

        /// The item this press acted on, when it produced one. Callers that need
        /// the item's CURRENT state (the App Intents verify a save actually
        /// landed) must re-read the store by this id: the copy carried here is
        /// the pre-ingest placeholder, and its URL may still be an unresolved
        /// wrapper.
        public var item: ReadingListItem? {
            switch self {
            case let .saved(item), let .sentToEreaders(item),
                 let .sentToFriends(item), let .friendPromptRequested(item):
                return item
            case .unsupportedKind, .ignored:
                return nil
            }
        }
    }

    /// The save-press entry point shared by the intents and the in-app add:
    /// first press saves and ingests; a second press within a few seconds
    /// triggers the fixed Kindle double-save behavior; any other press on an
    /// existing URL is ignored. Awaits the resulting work (callers bound it
    /// with a timeout).
    ///
    /// `doubleSaveActionSurface`: non-nil ONLY for saves arriving through the
    /// Action Button's Save App Intent on a surface with the double-save action
    /// enabled (today: Reader). It switches a repeat press into the 7 s
    /// Kindle-or-no-op regime instead of the legacy ereader double save.
    @discardableResult
    public func handleSavePress(urlString: String, source: CaptureSource = .manual,
                                prefetchedHTML: String? = nil,
                                trustsPrefetchedHTML: Bool = false,
                                doubleSaveActionSurface: String? = nil) async -> SavePressResult {
        guard let url = URLUnwrapper.ingestURL(from: urlString) else { return .ignored }
        let urlString = url.absoluteString
        let existing = store.item(forURLString: urlString)
        let previousPress = existing.map { store.recordSaveAttempt(for: $0.id) } ?? nil

        let decision = SavePressPolicy.decide(
            existingItem: existing,
            previousPressDate: previousPress,
            now: Date(),
            doubleSaveDestinationIDs: IngestorKindHandlers.article?.doubleSaveDestinationIDs() ?? [],
            intentAction: doubleSaveActionSurface.flatMap(Self.resolvedIntentAction(forSurface:)))

        switch decision {
        case .saveNew:
            let item = store.add(urlString: urlString, source: source)
            // App-Intent saves WAIT for the classified outcome (bounded by the
            // intent layer's own 12 s race, after which the ingest continues in
            // the background and persists pending work). Waiting is what lets an
            // intent report a real failure — a surface-dropped kind, an
            // unreachable page — instead of exiting with silent success over an
            // empty or `.failed` item. The central Luna app used to skip the wait
            // because its gate can never drop a kind, but it can still fail to
            // fetch, and that has to reach the user too.
            let decision = await ingest(item, prefetchedHTML: prefetchedHTML,
                                        trustsPrefetchedHTML: trustsPrefetchedHTML)
            switch decision {
            case let .unsupported(owner):
                return .unsupportedKind(owner: owner)
            case .supported:
                return .saved(item)
            }
        case .sendToEreaders(let destinationIDs):
            // The policy only returns this for an existing item.
            guard let existing else { return .ignored }
            for destinationID in destinationIDs {
                await IngestorKindHandlers.article?.sendToDestination(
                    existing, destinationID: destinationID)
            }
            return .sentToEreaders(existing)
        case .sendToFriends(let emails):
            guard let existing else { return .ignored }
            do {
                try await EmailShareCenter.shared.send(item: existing, to: emails)
                SharedDiagnosticLog.record(
                    "double save: emailed \(existing.urlString) to \(emails.count) friend(s)",
                    category: "send")
            } catch {
                // A failed friend send must not fail the save intent.
                SharedDiagnosticLog.record(
                    "double save: friend send failed: \(error)", category: "send")
            }
            return .sentToFriends(existing)
        case .promptFriendSelector:
            guard let existing, let surface = doubleSaveActionSurface else { return .ignored }
            DoubleSaveActionStore.shared.setPendingFriendPrompt(
                urlString: existing.urlString, forSurface: surface)
            return .friendPromptRequested(existing)
        case .ignore:
            return .ignored
        }
    }

    /// Arms the fixed Action Button double-save behavior. A configured Kindle
    /// receives the article; without one, the repeat press does nothing.
    private static func resolvedIntentAction(
        forSurface _: String
    ) -> SavePressPolicy.IntentAction? {
        guard IngestorKindHandlers.article?.isDestinationConfigured(
            ArticleDestinationID.kindle) ?? false else { return nil }
        return .sendToKindle
    }

    /// Saves `urlString` as a normal article, bypassing product-page detection. Used
    /// by the price-tracking editor's "Read instead" override: a URL that WAS
    /// classified as a tracker is re-saved here as a plain article (it must not be
    /// re-detected back into a tracker). Adds a fresh item when none exists, then
    /// ingests it with detection forced off.
    public func saveAsArticle(urlString: String, source: CaptureSource = .manual) async {
        guard let url = URLUnwrapper.ingestURL(from: urlString) else { return }
        let urlString = url.absoluteString
        let item = store.item(forURLString: urlString) ?? store.add(urlString: urlString, source: source)
        await ingest(item, forceArticle: true)
    }

    /// Saves a NEW URL whose article content was already fetched (the pasteboard
    /// preview), persisting it directly so we skip a redundant network fetch.
    ///
    /// The direct-persist fast path bypasses `ingest`, so the surface gate runs
    /// here explicitly: the pre-fetched content IS the classified outcome (an
    /// article — Reader-owned), so a foreign-kind paste is refused before
    /// anything is added, with the same interactive error.
    @discardableResult
    public func saveNewWithContent(
        urlString: String, content: ArticleContent, source: CaptureSource = .manual
    ) async -> ReadingListItem? {
        guard let url = URLUnwrapper.ingestURL(from: urlString) else { return nil }
        let urlString = url.absoluteString

        if case let .unsupported(owner) = surfaceDecision(.article(content, html: "")) {
            await presentUnsupportedSave(
                owner: owner, source: source, allowsInteractivePrompt: true,
                logMessage: "surface: dropped reader-owned paste save — refused",
                discard: {})
            return nil
        }

        let item = store.add(urlString: urlString, source: source)
        // The pre-fetched content was extracted from `urlString` as given. If that
        // URL is a wrapper (Facebook deep link / Apple-Google News / shortener), the
        // pre-fetched content is the wrapper shell, not the article — so unwrap and
        // run the full pipeline on the real URL instead of persisting the stale shell.
        // A non-wrapper URL keeps the fast path (persist the content directly).
        if await URLUnwrapper.unwrap(url).didUnwrap {
            await ingest(item)
            return store.item(withID: item.id) ?? item
        }
        let saved = store.saveContent(content, for: item)
        if saved.state == .ready {
            IngestorKindHandlers.article?.articleBecameReady(saved)
        }
        return saved
    }
}

/// The main-app (foreground reading-list) presenter: maps each `Outcome` to the
/// ingestor's store-writing helpers. Exhaustive — every case is handled, so a new
/// `Outcome` kind can't be silently dropped. This is the headless persistence
/// presenter shared by interactive saves (paste/manual), app intents, and incoming
/// friend shares; the foreground list opens the saved item via
/// `ReadingListViewController.open(_:presenter:)` when tapped.
public struct IngestorOutcomePresenter: OutcomePresenter {
    public let ingestor: ReadingListIngestor
    public let url: URL

    public func present(_ outcome: Outcome, for item: ReadingListItem) async {
        switch outcome {
        case let .article(content, html):
            await ingestor.persistArticle(content, html: html, for: item, url: url)
        case let .product(product, _):
            await ingestor.ingestProductTracker(item, url: url, product: product)
        case let .video(platform, itemID):
            await ingestor.handleVideo(platform, itemID: itemID, for: item)
        case let .social(platform, itemID):
            await ingestor.handlePlatform(platform, itemID: itemID, for: item)
        case let .document(type):
            await ingestor.handleDocument(type: type, for: item)
        case let .needsArchive(title):
            await ingestor.parkNeedsArchive(title: title, for: item)
        case let .failed(reason):
            await ingestor.markFailed(for: item, reason: reason)
        case .unsupported:
            // Unreachable: the surface gate in `applyResult` discards an
            // unsupported outcome (and deletes the item) before presenting.
            assertionFailure("unsupported outcome reached the presenter")
        }
    }
}
