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
    /// `ProductPriceRescue.resolver` — LunaReadingList
    /// can't know how the app presents modals.
    public static var unsupportedSavePresenter: (@MainActor (_ owner: LunaApp) -> Void)?

    /// Installed by the app shell (`URLRescueWiring`) so a `.failed` first pass can
    /// hand the item to `URLRescueCoordinator`. nil in extensions / tests (rescue
    /// is main-app-only), where a failure just stays failed. Params: the item id,
    /// the resolved URL, the capture source, and whether this was an interactive
    /// (foreground, user-initiated) save.
    public static var rescueTrigger: ((UUID, URL, CaptureSource, _ interactive: Bool) -> Void)?

    /// Installed by a product-handling app's `KindWiring` (`SellerComparison
    /// .beginAndRunInBackground`, via a thin adapter — `LunaReadingList` cannot
    /// link `LunaPriceUI`). Called from the re-save dedup below when a
    /// re-saved URL merges into a tracker that has never been through a
    /// fan-out and still has fewer than two stores, so a repeat save of an
    /// Amazon-style product actually attempts seller discovery instead of
    /// showing nothing (`claudedocs/price-comparison.md`'s "re-saves of a
    /// seller-less tracker kick a comparison"). nil in a process that hasn't
    /// composed the product kind, where nothing runs anyway.
    public static var priceTrackerComparisonKicker: ((UUID, URL, ReadingListStore) -> Void)?

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
    /// tracker. Used when a rescue directive's hint is `.article` (`RescueDirectiveApplier`).
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

        let alreadyRunning = lock.withLock {
            let running = inFlight.contains(item.id)
            if !running { inFlight.insert(item.id) }
            return running
        }
        guard !alreadyRunning else { return .supported }
        defer { lock.withLock { _ = inFlight.remove(item.id) } }

        let url = initialURL

        // Everything this save's legs observe goes into ONE buffered trace,
        // correlated by the item's id and mirrored line-by-line into the general
        // diagnostics stream. Bound as a task-local, so the fetcher, the bypass
        // runner, the classifier and the resolvers record without threading an
        // argument through six modules (`claudedocs/save-diagnostics.md`).
        let recorder = SaveDiagnosticsRecorder(itemID: item.id) { message, category in
            DiagnosticLog.shared.record(message, category: category)
        }
        recorder.record(
            "ingest: begin \(SaveDiagnostics.url(url)) source=\(item.effectiveCaptureSource.rawValue)"
                + (forceArticle ? " forceArticle" : "")
                + (prefetchedHTML != nil ? " prefetchedHTML=\(prefetchedHTML?.count ?? 0)ch" : ""),
            category: "ingest")

        // The ONE shared pipeline resolves wrappers, classifies, and processes every
        // URL. Its result carries the exact final URL, so this store is repointed
        // without independently repeating the unwrap work.
        let result = await SaveDiagnostics.$recorder.withValue(recorder) {
            await IngestPipeline.processResolved(
                IngestInput(url: url, source: item.effectiveCaptureSource,
                            documentType: item.sanitizedDocumentType,
                            prefetchedHTML: prefetchedHTML, forceArticle: forceArticle,
                            trustsPrefetchedHTML: trustsPrefetchedHTML),
                fetcher: fetcher)
        }

        // A normal App Intent may cancel this work when its 20 s fast-path
        // budget expires, then resume it under SaveIntent's extended runtime.
        // Do not persist the losing task's result after cancellation: the
        // pending placeholder is the durable checkpoint and the resumed run
        // will apply exactly one result.
        guard !Task.isCancelled else { return .supported }

        // The persist tail stays inside the binding: the media leg only learns
        // that a classified post has no downloadable asset while its handler
        // runs, and that discovery belongs in the same trace.
        let decision = await SaveDiagnostics.$recorder.withValue(recorder) {
            await applyResult(
                result, for: item, forceArticle: forceArticle,
                allowsInteractivePrompt: allowsInteractivePrompt)
        }
        flushDiagnostics(recorder, outcome: result.outcome, decision: decision,
                         source: item.effectiveCaptureSource)

        // URL-Rescue hook: a genuine `.failed` first pass is the one place a
        // rescue may help. `itemJustFailed` re-reads the item from the store and
        // no-ops unless it's still `.failed` and rescue is eligible — so a
        // surface-dropped or already-existing item never triggers one. The rescue
        // engine re-enters the RAW pipeline (not this method), so it can't recurse.
        // `.notContent` is the one failure a rescue cannot help with — there is no
        // article on a search-results or index page for the model to find, and the
        // attempt is rationed per app version (`claudedocs/failed-saves.md`).
        if case let .failed(reason) = result.outcome,
           reason?.isWorthRescuing ?? true {
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
           let (existingTrackerItemID, existingTracker) = store.priceTracker(
               containingStoreURL: resolvedURL.absoluteString),
           existingTrackerItemID != item.id {
            store.delete(item)
            PriceTrackerSaveAnnouncement.post(
                itemID: existingTrackerItemID, source: item.effectiveCaptureSource,
                isMerge: true, highlightedURL: resolvedURL.absoluteString)
            // A tracker that has never been through a fan-out and still has
            // fewer than two stores has effectively never been compared —
            // this is the repeat-save case that used to leave an Amazon-style
            // product with no seller row and no spinner, forever.
            if existingTracker.pendingComparison == nil, existingTracker.stores.count < 2 {
                Self.priceTrackerComparisonKicker?(existingTrackerItemID, resolvedURL, store)
            }
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

    /// Commits or discards a save's buffered trace, which is the whole point of
    /// buffering it: a save that worked leaves nothing behind (and sheds any
    /// trace an EARLIER failed attempt left, so a recovered item stops carrying
    /// a stale story), while a save that failed writes its complete attempt to
    /// the item's sidecar under an attempt separator.
    ///
    /// Retries append rather than replace — the launch sweep re-enters `ingest`
    /// for every `.failed` item, so the file accumulates "attempt 1 …, attempt
    /// 2 …" and the shared export shows whether the failure is stable.
    ///
    /// A surface-DROPPED save (another app's kind) is not a failure of this app
    /// and its item no longer exists, so it discards like a success.
    private func flushDiagnostics(
        _ recorder: SaveDiagnosticsRecorder, outcome: Outcome,
        decision: SurfaceSupport.Decision, source: CaptureSource
    ) {
        let reason: SaveFailureReason?
        let failed: Bool
        if case let .failed(outcomeReason) = outcome {
            failed = true
            reason = outcomeReason
        } else {
            // A classified-but-broken save (media with no downloadable asset)
            // reports a success outcome and marks the recorder instead.
            reason = recorder.terminalFailure
            failed = reason != nil
        }

        guard failed, decision == .supported else {
            _ = recorder.drainLines()
            SaveDiagnosticsStore.shared.delete(for: recorder.itemID)
            return
        }

        let lines = recorder.drainLines()
        guard !lines.isEmpty else { return }
        let attempt = SaveFailureStore.shared.record(for: recorder.itemID)?.failureCount ?? 1
        let separator = "— attempt \(attempt) via \(source.rawValue), "
            + (reason.map { String(describing: $0) } ?? "unknown") + " —"
        SaveDiagnosticsStore.shared.appendLines([separator] + lines, for: recorder.itemID)
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

    /// An `.unsupported` outcome reached the presenter of a process whose surface
    /// gate ACCEPTS that kind — the same class of programming error as a missing
    /// handler, and given the same release behavior: the row is marked failed so
    /// the list shows it, instead of spinning as `.pending` forever.
    fileprivate func markUnsupportedFailed(
        owner: LunaApp, for item: ReadingListItem
    ) async {
        SharedDiagnosticLog.record(
            "ingest: unsupported outcome (owner \(owner.storageIdentifier)) reached the "
                + "presenter — marking \(item.id) failed",
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
            let items = self.store.items()
            for item in items where item.state == .pending || item.state == .failed {
                Task { await self.ingest(item, allowsInteractivePrompt: false) }
            }
            // The sweep already holds the whole list, which is the one thing a
            // trace-file prune needs: a `saveDiagnostics/<uuid>.log` whose item
            // was deleted from another app (or wiped by a reinstall of a
            // sibling) has nothing left to explain.
            SaveDiagnosticsStore.shared.prune(keeping: Set(items.map(\.id)))
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
        /// Double press — the caller should build this item in this format and
        /// return the file as the App Intent's media. The file itself is NOT
        /// built here: serialization lives in LunaSend, an article-kind module
        /// this universal one can't link, so the intent layer does it through
        /// an injected seam.
        case exportRequested(ReadingListItem, ArticleExportFormat)
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
                 let .sentToFriends(item), let .friendPromptRequested(item),
                 let .exportRequested(item, _):
                return item
            case .unsupportedKind, .ignored:
                return nil
            }
        }
    }

    /// A durable, Codable save-press decision. App Intents prepare this before
    /// starting network work, so a normal-runtime intent can be cancelled at its
    /// deadline and the LongRunning Save intent can resume without reserving the
    /// URL a second time or accidentally turning the resume into a double save.
    public struct PreparedSavePress: Codable, Equatable, Sendable {
        public enum Action: Codable, Equatable, Sendable {
            case saveNew
            case sendToEreaders(destinationIDs: [String])
            case sendToFriends(emails: [String])
            case promptFriendSelector
            case exportArticle(format: ArticleExportFormat)
            case ignore
        }

        public let itemID: UUID
        public let urlString: String
        public let action: Action
        public let isDoubleSave: Bool
        public let doubleSaveActionSurface: DoubleSaveSurface?
        public let attemptDate: Date

        public init(
            itemID: UUID, urlString: String, action: Action,
            isDoubleSave: Bool, doubleSaveActionSurface: DoubleSaveSurface?, attemptDate: Date
        ) {
            self.itemID = itemID
            self.urlString = urlString
            self.action = action
            self.isDoubleSave = isDoubleSave
            self.doubleSaveActionSurface = doubleSaveActionSurface
            self.attemptDate = attemptDate
        }
    }

    /// Atomically reserves a save press and freezes its policy decision before
    /// any asynchronous work begins. The returned value is safe to encode into
    /// an App Intent handoff and execute later in another intent process.
    public func prepareSavePress(
        urlString: String, source: CaptureSource = .manual,
        doubleSaveActionSurface: DoubleSaveSurface? = nil,
        attemptDate: Date = Date()
    ) -> PreparedSavePress? {
        guard let url = URLUnwrapper.ingestURL(from: urlString) else { return nil }
        let urlString = url.absoluteString
        let reservation = store.reserveSaveAttempt(
            urlString: urlString, source: source, at: attemptDate)
        let existing = reservation.wasAdded ? nil : reservation.item
        let isDoubleSave = existing != nil
            && doubleSaveActionSurface != nil
            && (reservation.previousPressDate.map {
                abs(attemptDate.timeIntervalSince($0))
                    < SavePressPolicy.intentDoublePressWindow
            } ?? false)
        let regime: SavePressPolicy.SavePressRegime = doubleSaveActionSurface
            .flatMap(Self.resolvedIntentAction(forSurface:))
            .map(SavePressPolicy.SavePressRegime.actionButton)
            ?? .inApp(doubleSaveDestinationIDs: IngestorKindHandlers.article?.doubleSaveDestinationIDs() ?? [])
        let decision = SavePressPolicy.decide(
            existingItem: existing,
            previousPressDate: reservation.previousPressDate,
            now: attemptDate,
            regime: regime)
        return PreparedSavePress(
            itemID: reservation.item.id,
            urlString: urlString,
            action: Self.preparedAction(from: decision),
            isDoubleSave: isDoubleSave,
            doubleSaveActionSurface: doubleSaveActionSurface,
            attemptDate: attemptDate)
    }

    /// Executes a previously frozen save decision. `waitForInFlight` is used by
    /// a resumed Save intent: the cancelled Provide Context task may still be
    /// unwinding a URLSession/WebKit operation, and the resumed run must wait for
    /// that cleanup instead of treating an in-flight no-op as completion.
    @discardableResult
    public func performPreparedSavePress(
        _ prepared: PreparedSavePress,
        prefetchedHTML: String? = nil,
        trustsPrefetchedHTML: Bool = false,
        waitForInFlight: Bool = false
    ) async -> SavePressResult {
        if waitForInFlight {
            while isIngesting(prepared.itemID) {
                guard !Task.isCancelled else { return .ignored }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer { store.finishSaveAttempt(for: prepared.itemID) }

        switch prepared.action {
        case .saveNew:
            guard let item = store.item(withID: prepared.itemID) else {
                // A prior attempt can legitimately dedupe the placeholder into
                // an existing canonical item. Carrying an item in the result is
                // how intent verification recognizes that successful case.
                return .saved(ReadingListItem(urlString: prepared.urlString))
            }
            if item.state == .ready || item.state == .needsCaptcha { return .saved(item) }
            let decision = await ingest(
                item, prefetchedHTML: prefetchedHTML,
                trustsPrefetchedHTML: trustsPrefetchedHTML)
            switch decision {
            case let .unsupported(owner): return .unsupportedKind(owner: owner)
            case .supported: return .saved(item)
            }
        case .sendToEreaders(let destinationIDs):
            guard let existing = store.item(withID: prepared.itemID) else { return .ignored }
            for destinationID in destinationIDs {
                await IngestorKindHandlers.article?.sendToDestination(
                    existing, destinationID: destinationID)
            }
            return .sentToEreaders(existing)
        case .sendToFriends(let emails):
            guard let existing = store.item(withID: prepared.itemID) else { return .ignored }
            do {
                try await EmailShareCenter.shared.send(item: existing, to: emails)
                SharedDiagnosticLog.record(
                    "double save: emailed \(existing.urlString) to \(emails.count) friend(s)",
                    category: "send")
            } catch {
                SharedDiagnosticLog.record(
                    "double save: friend send failed: \(error)", category: "send")
            }
            return .sentToFriends(existing)
        case .promptFriendSelector:
            guard let existing = store.item(withID: prepared.itemID),
                  let surface = prepared.doubleSaveActionSurface
            else { return .ignored }
            DoubleSaveActionStore.shared.setPendingFriendPrompt(
                urlString: existing.urlString, forSurface: surface)
            return .friendPromptRequested(existing)
        case .exportArticle(let format):
            guard let existing = store.item(withID: prepared.itemID) else { return .ignored }
            return .exportRequested(existing, format)
        case .ignore:
            return .ignored
        }
    }

    /// The save-press entry point shared by the intents and the in-app add:
    /// first press saves and ingests; a second press within a few seconds
    /// triggers the configured double-save behavior; any other press on an
    /// existing URL is ignored. Awaits the resulting work (callers bound it
    /// with a timeout).
    ///
    /// `doubleSaveActionSurface`: non-nil ONLY for saves arriving through the
    /// Action Button's Save App Intent on a surface that can act on a double
    /// save (the two article-file apps: Luna and Reader). It switches a repeat
    /// press into the 7 s `DoubleSaveAction` regime instead of the legacy
    /// ereader double save.
    @discardableResult
    public func handleSavePress(urlString: String, source: CaptureSource = .manual,
                                prefetchedHTML: String? = nil,
                                trustsPrefetchedHTML: Bool = false,
                                doubleSaveActionSurface: DoubleSaveSurface? = nil,
                                attemptDate: Date = Date()) async -> SavePressResult {
        guard let prepared = prepareSavePress(
            urlString: urlString, source: source,
            doubleSaveActionSurface: doubleSaveActionSurface,
            attemptDate: attemptDate)
        else { return .ignored }
        return await performPreparedSavePress(
            prepared, prefetchedHTML: prefetchedHTML,
            trustsPrefetchedHTML: trustsPrefetchedHTML)
    }

    private static func preparedAction(
        from decision: SavePressPolicy.Decision
    ) -> PreparedSavePress.Action {
        switch decision {
        case .saveNew: return .saveNew
        case .sendToEreaders(let ids): return .sendToEreaders(destinationIDs: ids)
        case .sendToFriends(let emails): return .sendToFriends(emails: emails)
        case .promptFriendSelector: return .promptFriendSelector
        case .exportArticle(let format): return .exportArticle(format: format)
        case .ignore: return .ignore
        }
    }

    /// Arms the Action Button double-save behavior from the user's setting
    /// (Settings → Shortcut & Safari). Never returns nil: an Action Button save
    /// always stays in the 7 s intent regime, so an unset or unusable action is
    /// an explicit no-op rather than a fall-through to the legacy in-app
    /// double save. "Send to Kindle" without a configured Kindle degrades the
    /// same way.
    private static func resolvedIntentAction(
        forSurface surface: DoubleSaveSurface
    ) -> SavePressPolicy.IntentAction? {
        switch DoubleSaveActionStore.shared.action(forSurface: surface) {
        case .nothing:
            return .doNothing
        case .sendToKindle:
            guard IngestorKindHandlers.article?.isDestinationConfigured(
                ArticleDestinationID.kindle) ?? false else { return .doNothing }
            return .sendToKindle
        case let action:
            guard let format = action.exportFormat else { return .doNothing }
            return .exportArticle(format: format)
        }
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
        case let .unsupported(owner):
            // The surface gate in `applyResult` discards an unsupported outcome
            // (and deletes the item) before presenting, so reaching here is a
            // programming error: loud in a debug app, and the row is marked failed
            // rather than left pending forever. The assertion stands down under
            // XCTest so the suite can drive the recovery it guards.
            if !LiveNetworkPolicy.isRunningUnderXCTest {
                assertionFailure("unsupported outcome reached the presenter")
            }
            await ingestor.markUnsupportedFailed(owner: owner, for: item)
        }
    }
}
