//
//  SavesIngestor.swift
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

/// The app's own diagnostics stream, which a save's trace is mirrored into as it
/// happens.
private struct AppDiagnosticsMirror: SaveDiagnosticsMirroring {
    func mirror(message: String, category: String) {
        DiagnosticLog.shared.record(message, category: category)
    }
}

/// Presents the unsupported-kind error for a dropped interactive in-app save.
/// The app shell installs this at launch (AppDelegate) — LunaSaves cannot
/// know how the app presents modals.
public protocol UnsupportedSavePresenting {
    @MainActor
    func presentUnsupportedSave(owner: LunaApp)
}

/// Hands a `.failed` first pass to `URLRescueCoordinator`. Installed by the app
/// shell (`URLRescueWiring`); uninstalled in extensions / tests (rescue is
/// main-app-only), where a failure just stays failed.
public protocol IngestRescueTriggering {
    func itemFailedIngest(itemID: UUID, url: URL, source: CaptureSource)
}

/// Starts an alternative-seller fan-out for a re-saved product URL. Installed by
/// a product-handling app's `KindWiring` (`LunaSaves` cannot link
/// `LunaPriceUI`); uninstalled in a process that hasn't composed the product
/// kind, where nothing runs anyway.
public protocol PriceTrackerComparisonKicking {
    func kickComparison(itemID: UUID, url: URL, store: SavesStore)
}

/// The per-app content gate over a classified outcome (`SurfaceSupport`): a
/// single-content app drops foreign kinds before any store write.
///
/// This has the same shape as `LunaShareSurface`'s `ShareSurfaceGating`,
/// declared again here because this module sits below LunaShareSurface and
/// cannot see it. The two are deliberately independent one-method contracts
/// rather than a shared one hoisted into a module neither needs.
public protocol IngestSurfaceGating {
    func decision(for outcome: Outcome) -> SurfaceSupport.Decision
}

/// The production gate: the app this process is actually running in.
public struct CurrentProcessIngestGate: IngestSurfaceGating {
    public init() {}

    public func decision(for outcome: Outcome) -> SurfaceSupport.Decision {
        SurfaceSupport.evaluateForCurrentProcess(owner: outcome.owningApp)
    }
}

/// Downloads and extracts content for saved items: the immediate step
/// after a link is saved, plus a retry pass for anything still pending.
public final class SavesIngestor: PluginLockedSaveResuming {
    public static let shared = SavesIngestor()

    public func persistPlainLink(_ item: SavedItem) { store.markPlainLink(item.id) }

    private let store: SavesStore
    private let fetcher = ArticleFetcher()
    /// The per-app content gate over a classified outcome (`SurfaceSupport`).
    /// Injectable so tests can pin the running app without touching
    /// `Bundle.main`; the production default reads the running process's app.
    private let surfaceGate: any IngestSurfaceGating

    /// The unsupported-kind error for a dropped interactive in-app save —
    /// `.paste`/`.manual` sources only. App Intents get a dialog from the
    /// intent layer, and background sweeps have no UI.
    public static var unsupportedSavePresenter: (any UnsupportedSavePresenting)?

    /// Where a `.failed` first pass goes for a rescue attempt.
    public static var rescueTrigger: (any IngestRescueTriggering)?

    /// The seller fan-out for a re-save (`SellerComparison
    /// .beginAndRunInBackground`, via a thin adapter). Called from the re-save
    /// dedup below when a re-saved URL merges into a tracker that has never been
    /// through a fan-out and still has fewer than two stores, so a repeat save
    /// of an Amazon-style product actually attempts seller discovery instead of
    /// showing nothing (`claudedocs/price-comparison.md`'s "re-saves of a
    /// seller-less tracker kick a comparison").
    public static var priceTrackerComparisonKicker: (any PriceTrackerComparisonKicking)?

    public init(
        store: SavesStore = .shared,
        surfaceGate: any IngestSurfaceGating = CurrentProcessIngestGate()
    ) {
        self.store = store
        self.surfaceGate = surfaceGate
        self.transcriptions = TranscriptionJobStore(saves: store)
    }

    /// The transcription job rows over this ingestor's store. A save with a row
    /// belongs to the transcription runner, and this ingestor never re-walks it
    /// (`claudedocs/plans/transcription-plugins.md` decision 3).
    private let transcriptions: TranscriptionJobStore

    /// IDs currently being ingested, to avoid duplicate concurrent work.
    private var inFlight = Set<UUID>()
    private let lock = NSLock()

    /// Whether `id` is mid-ingest right now — the rescue sweep checks this to
    /// avoid racing an in-progress primary ingest.
    public func isIngesting(_ id: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight.contains(id)
    }

    /// Runs `ingestAllPending()`'s enumeration (a full list read) and backfill
    /// scans off the caller's thread. Launch, foreground, and pull-to-refresh
    /// all call it synchronously, and none of them should block on it.
    private let sweepQueue = DispatchQueue(
        label: "com.hsanabria.luna.savesIngestor.sweep", qos: .utility)

    /// Fetches and extracts content for one item. Safe to call repeatedly.
    ///
    /// `forceArticle` skips product-page detection entirely, so the URL is ingested
    /// as a normal article even if its page would otherwise be classified as a price
    /// tracker. Used when a rescue directive's hint is `.article` (`RescueDirectiveApplier`).
    ///
    /// The per-app content gate (`SurfaceSupport`) runs on the classified
    /// outcome before any store write: a foreign-kind save is discarded (item
    /// deleted, nothing remains) and the returned decision says so, for every
    /// source including `.email`/`.friendShare` — the owning app's own import
    /// picks up the same message when it is installed.
    /// `allowsInteractivePrompt` is false for the background `ingestAllPending`
    /// sweep, which discards dropped leftovers silently; interactive saves
    /// (`.paste`/`.manual`) surface the error via `unsupportedSavePresenter`.
    @discardableResult
    public func ingest(_ item: SavedItem, forceArticle: Bool = false,
                       page: CapturedPage = .none,
                       allowsInteractivePrompt: Bool = true,
                       intent: IngestIntent? = nil) async -> SurfaceSupport.Decision {
        guard item.state != .ready, let initialURL = item.url else { return .supported }
        // A queued transcription is the runner's. Re-walking it would queue a
        // second job, or hand a failed article attempt to a media plugin.
        guard !transcriptions.hasJob(saveID: item.id) else { return .supported }

        let alreadyRunning = lock.withLock {
            let running = inFlight.contains(item.id)
            if !running { inFlight.insert(item.id) }
            return running
        }
        guard !alreadyRunning else { return .supported }
        defer { lock.withLock { _ = inFlight.remove(item.id) } }

        let url = initialURL

        // Everything this save's legs observe goes into one buffered trace,
        // correlated by the item's id and mirrored line-by-line into the
        // general diagnostics stream. It is bound as a task-local, so the
        // fetcher, the bypass runner, the classifier, and the resolvers
        // record without threading an argument through six modules
        // (`claudedocs/save-diagnostics.md`).
        let recorder = SaveDiagnosticsRecorder(
            itemID: item.id, mirror: AppDiagnosticsMirror())
        recorder.record(
            "ingest: begin \(SaveDiagnostics.url(url)) source=\(item.effectiveCaptureSource.rawValue)"
                + (forceArticle ? " forceArticle" : "")
                + (intent.map { " intent=\($0.rawValue)" } ?? "")
                + (page.html.map { " prefetchedHTML=\($0.count)ch" } ?? ""),
            category: "ingest")

        // The one shared pipeline resolves wrappers, classifies, and
        // processes every URL. Its result carries the exact final URL, so
        // this store is repointed without repeating the unwrap work.
        let result = await SaveDiagnostics.$recorder.withValue(recorder) {
            await IngestPipeline.processResolved(
                IngestInput(url: url, source: item.effectiveCaptureSource,
                            documentType: item.sanitizedDocumentType,
                            page: page, forceArticle: forceArticle, intent: intent),
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

        // URL Rescue hook: a genuine `.failed` first pass is the one place a
        // rescue may help. `itemJustFailed` re-reads the item from the store
        // and no-ops unless rescue is still owed to it, so a surface-dropped or
        // already-existing item never triggers one. The rescue engine re-enters
        // the raw pipeline, not this method, so it cannot recurse. `.notContent`
        // is the one failure a rescue cannot help with — there is no article on
        // a search-results or index page for the model to find
        // (`claudedocs/failed-saves.md`).
        if case let .failed(reason) = result.outcome,
           reason?.isWorthRescuing ?? true {
            Self.rescueTrigger?.itemFailedIngest(
                itemID: item.id, url: result.url,
                source: item.effectiveCaptureSource)
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
        _ result: IngestResult, for item: SavedItem, forceArticle: Bool,
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

        // Per-app content gate, before the tracker-merge dedup below and
        // before the presenter, so a dropped outcome can neither merge into
        // an existing tracker nor write anything else. Every source is gated.
        let source = item.effectiveCaptureSource
        let decision = surfaceGate.decision(for: result.outcome)
        if case let .unsupported(owner) = decision {
            await presentUnsupportedSave(
                owner: owner, source: source,
                allowsInteractivePrompt: allowsInteractivePrompt,
                logMessage: "surface: dropped \(owner.storageIdentifier)-owned save — discarded",
                discard: { store.delete(item) })
            return decision
        }

        // Re-save dedup after resolution: if this exact URL is already a
        // store inside an existing price tracker, it was already classified
        // as price-tracking on a previous save. The merge path deletes the
        // placeholder, so a re-save arrives as a fresh placeholder here.
        if !forceArticle,
           let (existingTrackerItemID, existingTracker) = store.priceTracker(
               containingStoreURL: resolvedURL.absoluteString),
           existingTrackerItemID != item.id {
            store.delete(item)
            PriceTrackerSaveAnnouncement.post(
                itemID: existingTrackerItemID, source: item.effectiveCaptureSource,
                isMerge: true, highlightedURL: resolvedURL.absoluteString)
            // A tracker that has never been through a fan-out and still has
            // fewer than two stores has effectively never been compared. A
            // repeat save is the trigger that gives an Amazon-style product
            // its seller row and comparison spinner.
            if existingTracker.pendingComparison == nil, existingTracker.stores.count < 2 {
                Self.priceTrackerComparisonKicker?.kickComparison(
                    itemID: existingTrackerItemID, url: resolvedURL, store: store)
            }
            return decision
        }

        // A plugin-produced save carries its owner from here on. Stamped before
        // the presenter runs, so the write the presenter makes already has it.
        if let pluginID = result.pluginID {
            store.setPluginID(pluginID, for: item.id)
            item = store.item(withID: item.id) ?? item
        }

        let presenter = IngestorOutcomePresenter(ingestor: self, url: resolvedURL)
        await presenter.present(result.outcome, for: item)
        return decision
    }

    /// Re-runs the pipeline for a save a plugin locked, keeping its id
    /// (`claudedocs/plans/plugin-platform.md` §8.3).
    ///
    /// It is a plain re-ingest of the same row, so the walk reaches the same
    /// plugin, its `luna.browser.open` is answered from the stored result
    /// instead of a modal, and the Model it finally returns replaces the locked
    /// placeholder rather than adding a second save.
    public func resumePluginLockedSave(id: UUID) async {
        guard let item = store.item(withID: id),
              item.isPluginLocked || (URLBehaviorPolicy.pluginsOnly && item.state == .needsCaptcha) else { return }
        SharedDiagnosticLog.record(
            "plugin: resuming locked save \(id.uuidString.prefix(8))", category: "plugin")
        await ingest(item)
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

    /// Commits or discards a save's buffered trace, which is the whole point
    /// of buffering it. A save that worked leaves nothing behind, and sheds
    /// any trace an earlier failed attempt left, so a recovered item stops
    /// carrying a stale story. A save that failed writes its complete
    /// attempt to the item's sidecar under an attempt separator.
    ///
    /// Retries append rather than replace — the launch sweep re-enters `ingest`
    /// for every `.failed` item, so the file accumulates "attempt 1 …, attempt
    /// 2 …" and the shared export shows whether the failure is stable.
    ///
    /// A surface-dropped save (another app's kind) is not a failure of this
    /// app, and its item no longer exists, so it discards like a success.
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
            Self.unsupportedSavePresenter?.presentUnsupportedSave(owner: owner)
        }
    }

    // MARK: - Outcome handling (the main-app presenter, store-writing)

    /// Persists a readable article via the registered article handler.
    fileprivate func persistArticle(
        _ content: ArticleContent, html: String, for item: SavedItem, url: URL
    ) async {
        guard let handler = IngestorKindHandlers.article else {
            missingHandlerFallback(kind: "article", for: item)
            return
        }
        await handler.persistArticle(content, html: html, for: item, url: url, store: store)
    }

    /// Parks a paywalled article for the interactive archive reader.
    fileprivate func parkNeedsArchive(title: String, for item: SavedItem) async {
        store.markNeedsCaptcha(item.id, title: title)
    }

    /// Parks a save whose plugin handed over a recording. The save stays
    /// `.pending` under the recording's title; the job row hands it to the
    /// central app's transcription runner, and `ingest` leaves it alone from
    /// here on.
    fileprivate func parkTranscription(_ request: TranscriptionRequest, for item: SavedItem) async {
        store.setPendingTitle(item.id, title: request.title)
        transcriptions.enqueue(saveID: item.id, request: request)
        SaveDiagnostics.record(
            "transcription: queued by plugin \(request.pluginID) "
                + "(\(request.mediaKind.rawValue), audio leg: \(request.audioURL == nil ? "no" : "yes"))",
            category: "transcription")
    }

    /// Parks a save whose plugin needs a browser this process cannot present.
    /// The row lands in the same `.needsCaptcha` lock the archive path uses, so
    /// every deck and both extensions already draw it; the plugin id is what
    /// the app reads to present that plugin's own browser request later.
    fileprivate func parkPluginLocked(pluginID: String, for item: SavedItem) async {
        store.markPluginLocked(item.id, pluginID: pluginID, title: item.title)
        SaveDiagnostics.record(
            "locked by plugin \(pluginID) — waiting for the app's browser step",
            category: "plugin")
    }

    /// Marks a genuine failure, and files the reason in the sidecar so the
    /// failed card can explain itself instead of showing one generic
    /// sentence.
    fileprivate func markFailed(for item: SavedItem, reason: SaveFailureReason? = nil) async {
        store.markFailed(item.id)
        SaveFailureStore.shared.recordFailure(item.id, reason: reason)
    }

    /// Ingests a document outcome via the registered article handler (documents
    /// are article-kind: they read in the article reader and are Kindle-eligible).
    fileprivate func handleDocument(type: String, for item: SavedItem) async {
        guard let handler = IngestorKindHandlers.article else {
            missingHandlerFallback(kind: "article (document)", for: item)
            return
        }
        await handler.ingestDocument(item, store: store)
    }

    /// Ingests a recognized video or social-platform outcome via the
    /// registered media handler.
    fileprivate func handleMediaPlatform(
        _ platform: ContentPlatform, itemID: String?, for item: SavedItem
    ) async {
        await ingestPlatformItem(item, platform: platform, itemID: itemID)
    }

    /// Turns a detected product page into a price tracker via the registered
    /// product handler.
    fileprivate func ingestProductTracker(
        _ item: SavedItem, url: URL, product: ProductInfo
    ) async {
        guard let handler = IngestorKindHandlers.product else {
            missingHandlerFallback(kind: "product", for: item)
            return
        }
        await handler.ingestProductTracker(item, url: url, product: product, store: store)
    }

    /// Ingests a recognized platform item via the registered media handler.
    private func ingestPlatformItem(
        _ item: SavedItem, platform: ContentPlatform, itemID: String?
    ) async {
        guard let handler = IngestorKindHandlers.media else {
            missingHandlerFallback(kind: "media", for: item)
            return
        }
        await handler.ingestPlatformItem(
            item, platform: platform, platformItemID: itemID, store: store)
    }

    /// A kind reached the presenter without its handler registered. That is a
    /// programming error: the `SurfaceSupport` gate runs before presentation,
    /// so an app only ever presents kinds it declared, and its composition
    /// root (`KindWiring`) must have installed the matching handler. This
    /// fails loudly in debug; in release, it marks the item failed rather
    /// than leaving it pending.
    private func missingHandlerFallback(kind: String, for item: SavedItem) {
        assertionFailure("no IngestorKindHandlers handler registered for \(kind)")
        SharedDiagnosticLog.record(
            "ingest: no \(kind) handler registered — marking \(item.id) failed",
            category: "ingest")
        store.markFailed(item.id)
        SaveFailureStore.shared.recordFailure(item.id, reason: .unknown)
    }

    /// An `.unsupported` outcome reached the presenter of a process whose
    /// surface gate accepts that kind — the same class of programming error
    /// as a missing handler, with the same release behavior: the row is
    /// marked failed so the list shows it, instead of spinning as `.pending`
    /// forever.
    fileprivate func markUnsupportedFailed(
        owner: LunaApp, for item: SavedItem
    ) async {
        SharedDiagnosticLog.record(
            "ingest: unsupported outcome (owner \(owner.storageIdentifier)) reached the "
                + "presenter — marking \(item.id) failed",
            category: "ingest")
        store.markFailed(item.id)
        SaveFailureStore.shared.recordFailure(item.id, reason: .unknown)
    }

    /// Kicks off ingestion for everything not yet ready (app launch or
    /// foreground). The enumeration (`store.items()` decode) and the two
    /// backfill scans run off the caller's thread on `sweepQueue`. Per-item
    /// ingestion is already async (`Task { await self.ingest(item) }`), and
    /// the backfills already hop to `@MainActor` internally for their own
    /// store reads, so this only changes which thread performs the initial
    /// decode and candidate scan.
    /// `completion` is a test seam: it fires once the sweep body has run, not
    /// the fire-and-forget per-item and backfill work it spawns.
    public func ingestAllPending(completion: (() -> Void)? = nil) {
        sweepQueue.async {
            // `.needsCaptcha` items can only advance when the user solves the
            // archive CAPTCHA, so a background re-fetch cannot help them —
            // this retries only the states an automated pass can actually
            // move forward. The sweep has no UI: blocked non-exempt
            // leftovers are discarded silently, while email/friend-share
            // items stay exempt.
            let items = self.store.items()
            // A save with a transcription job is finished by the runner, not by
            // a re-walk: re-ingesting it would queue a second job, and a failed
            // one would lose its transcribe intent to a media plugin.
            let transcribing = self.transcriptions.saveIDsWithJobs()
            for item in items
            where (item.state == .pending || item.state == .failed)
                && !transcribing.contains(item.id) {
                Task { await self.ingest(item, allowsInteractivePrompt: false) }
            }
            // The sweep already holds the whole list, which is the one thing
            // a trace-file prune needs: a `saveDiagnostics/<uuid>.log` whose
            // item was deleted from another app, or wiped by a reinstall of
            // a sibling, has nothing left to explain.
            SaveDiagnosticsStore.shared.prune(keeping: Set(items.map(\.id)))
            self.backfillMissingWebArchives()
            self.backfillMissingThumbnails()
            completion?()
        }
    }

    /// Repairs ready and locked web articles that have no row thumbnail. The
    /// action/share extension persists article content without fetching the
    /// page's cover image — it is short-lived and sandbox-limited — and
    /// locked rows can often still expose `og:image` before unlock. This
    /// delegates to the article handler, which owns the cover-fetch
    /// machinery and the per-session attempt state, and is a silent no-op in
    /// apps that do not handle articles, whose stores cannot contain
    /// thumbnail-less article rows in the first place.
    public func backfillMissingThumbnails() {
        IngestorKindHandlers.article?.backfillMissingThumbnails(store: store)
    }

    /// Backfills `.webarchive` capture for older items, and for saves from
    /// surfaces (extensions, paste, friend-share) that do not capture inline.
    /// This delegates to the article handler, which owns the WebKit capture
    /// machinery and the per-session attempt state, and is a silent no-op in
    /// apps that do not handle articles.
    public func backfillMissingWebArchives() {
        IngestorKindHandlers.article?.backfillMissingWebArchives(store: store)
    }

    /// What a save press did, so intents can wait on the right work.
    public enum SavePressResult {
        /// New URL — saved; ingestion may still be running.
        case saved(SavedItem)
        /// New URL whose classified outcome belongs to a kind this app does
        /// not handle: the item was discarded, and nothing remains in the
        /// store. Interactive in-app saves have already shown the
        /// unsupported-kind error by the time this returns; the Save App
        /// Intent turns it into an error dialog.
        case unsupportedKind(owner: LunaApp)
        /// Double press — the article was (re)sent to one or more ereaders.
        case sentToEreaders(SavedItem)
        /// Double press — the article was emailed to the preset friends.
        case sentToFriends(SavedItem)
        /// Double press — the app should open its friend selector for the item
        /// (the pending prompt is already recorded; the intent's caller returns
        /// the open-Luna token so the Shortcut foregrounds the app).
        case friendPromptRequested(SavedItem)
        /// Double press — the caller should build this item in this format and
        /// return the file as the App Intent's media. The file itself is not
        /// built here: serialization lives in LunaSend, an article-kind module
        /// this universal one cannot link, so the intent layer does it
        /// through an injected seam.
        case exportRequested(SavedItem, ArticleExportFormat)
        /// Duplicate press — nothing happened.
        case ignored

        /// The item this press acted on, when it produced one. A caller that
        /// needs the item's current state — the App Intents verify a save
        /// actually landed — must re-read the store by this id: the copy
        /// carried here is the pre-ingest placeholder, and its URL may still
        /// be an unresolved wrapper.
        public var item: SavedItem? {
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
        page: CapturedPage = .none,
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
                return .saved(SavedItem(urlString: prepared.urlString))
            }
            if item.state == .ready || item.state == .needsCaptcha { return .saved(item) }
            let decision = await ingest(item, page: page)
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
    /// `doubleSaveActionSurface` is non-nil only for saves arriving through
    /// the Action Button's Save App Intent, on a surface that can act on a
    /// double save (the two article-file apps: Luna and Reader). It switches
    /// a repeat press into the 7 s `DoubleSaveAction` regime instead of the
    /// legacy ereader double save.
    @discardableResult
    public func handleSavePress(urlString: String, source: CaptureSource = .manual,
                                page: CapturedPage = .none,
                                doubleSaveActionSurface: DoubleSaveSurface? = nil,
                                attemptDate: Date = Date()) async -> SavePressResult {
        guard let prepared = prepareSavePress(
            urlString: urlString, source: source,
            doubleSaveActionSurface: doubleSaveActionSurface,
            attemptDate: attemptDate)
        else { return .ignored }
        return await performPreparedSavePress(prepared, page: page)
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

    /// Saves a new URL whose article content was already fetched (the
    /// pasteboard preview), persisting it directly to skip a redundant
    /// network fetch.
    ///
    /// The direct-persist fast path bypasses `ingest`, so the surface gate
    /// runs here explicitly: the pre-fetched content is the classified
    /// outcome, an article, Reader-owned, so a foreign-kind paste is refused
    /// before anything is added, with the same interactive error.
    @discardableResult
    public func saveNewWithContent(
        urlString: String, content: ArticleContent, source: CaptureSource = .manual
    ) async -> SavedItem? {
        guard let url = URLUnwrapper.ingestURL(from: urlString) else { return nil }
        let urlString = url.absoluteString

        if case let .unsupported(owner) = surfaceGate.decision(for: .article(content, html: "")) {
            await presentUnsupportedSave(
                owner: owner, source: source, allowsInteractivePrompt: true,
                logMessage: "surface: dropped reader-owned paste save — refused",
                discard: {})
            return nil
        }

        let item = store.add(urlString: urlString, source: source)
        // The pre-fetched content was extracted from `urlString` as given. If
        // that URL is a wrapper (Facebook deep link, Apple/Google News,
        // shortener), the pre-fetched content is the wrapper shell, not the
        // article — so this unwraps and runs the full pipeline on the real
        // URL instead of persisting the stale shell. A non-wrapper URL keeps
        // the fast path and persists the content directly.
        if await URLUnwrapper.unwrap(url).didUnwrap {
            await ingest(item)
            return store.item(withID: item.id) ?? item
        }
        let saved = store.saveContent(content, for: item)
        if saved.state == .ready {
            SaveReadiness.observer?.saveBecameReady(saved)
        }
        return saved
    }
}

/// The main-app (foreground saves list) presenter: maps each `Outcome` to the
/// ingestor's store-writing helpers. It is exhaustive — every case is
/// handled, so a new `Outcome` kind cannot be silently dropped. This is the
/// headless persistence presenter shared by interactive saves (paste,
/// manual), app intents, and incoming friend shares. The card deck opens the
/// saved item through its kind's `CardKindPresenting` when tapped.
public struct IngestorOutcomePresenter: OutcomePresenter {
    public let ingestor: SavesIngestor
    public let url: URL

    public init(ingestor: SavesIngestor, url: URL) {
        self.ingestor = ingestor
        self.url = url
    }

    public func present(_ outcome: Outcome, for item: SavedItem) async {
        switch outcome {
        case .link:
            ingestor.persistPlainLink(item)
        case let .article(content, html):
            await ingestor.persistArticle(content, html: html, for: item, url: url)
        case let .product(product, _):
            await ingestor.ingestProductTracker(item, url: url, product: product)
        case let .video(platform, itemID), let .social(platform, itemID):
            await ingestor.handleMediaPlatform(platform, itemID: itemID, for: item)
        case let .document(type):
            await ingestor.handleDocument(type: type, for: item)
        case let .needsArchive(title):
            await ingestor.parkNeedsArchive(title: title, for: item)
        case let .transcription(request):
            await ingestor.parkTranscription(request, for: item)
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
        case let .locked(pluginID):
            await ingestor.parkPluginLocked(pluginID: pluginID, for: item)
        }
    }
}
