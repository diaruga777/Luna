//
//  ReadingListIngestor.swift
//  Luna
//

import LunaReaderUI
import LunaArchiveReader
import LunaMediaDownload
import LunaPlatforms
import LunaSend
import LunaDocuments
import LunaStorage
import LunaIngest
import LunaInterop
import LunaInteropUI
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
    private let extractor = ArticleExtractor()
    /// The cross-app-interop gate over a classified outcome
    /// (`claudedocs/interop-purchase.md`). Injectable so tests can pin
    /// surface/unlock/install without touching the App Group; the production
    /// default reads the running process's state.
    private let interopDecision: (Outcome) -> InteropGate.Decision

    /// Presents the interop prompt for a blocked / needs-install INTERACTIVE
    /// in-app save (`.paste`/`.manual` sources only — App Intents get a dialog
    /// from the intent layer, background sweeps have no UI). Installed by the
    /// app shell at launch (AppDelegate), same injected-closure pattern as
    /// `PriceTrackingViewController.defaultSaveAsArticle` — LunaReadingList
    /// can't know how the app presents modals. `retry` re-runs the save after
    /// a successful inline unlock (blocked case; nil for install notes).
    public static var interopPromptPresenter: (
        @MainActor (InteropPromptKind, _ retry: (() -> Void)?) -> Void)?

    public init(
        store: ReadingListStore = .shared,
        interopDecision: @escaping (Outcome) -> InteropGate.Decision = {
            InteropGate.evaluateForCurrentProcess(owner: $0.interopOwner)
        }
    ) {
        self.store = store
        self.interopDecision = interopDecision
    }

    /// IDs currently being ingested, to avoid duplicate concurrent work.
    private var inFlight = Set<UUID>()
    private let lock = NSLock()

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
    /// The cross-app-interop gate (`claudedocs/interop-purchase.md`) runs on the
    /// classified outcome before ANY store write: an unpaid cross-surface save is
    /// discarded (item deleted, nothing remains) and the returned decision says
    /// so. `.email`/`.friendShare` sources are exempt — background/universal
    /// ingestion keeps writing cross-surface regardless of payment.
    /// `allowsInteractivePrompt` is false for the background `ingestAllPending`
    /// sweep, which discards blocked leftovers silently; interactive saves
    /// (`.paste`/`.manual`) surface the prompt via `interopPromptPresenter`.
    @discardableResult
    public func ingest(_ item: ReadingListItem, forceArticle: Bool = false,
                       prefetchedHTML: String? = nil,
                       trustsPrefetchedHTML: Bool = false,
                       allowsInteractivePrompt: Bool = true) async -> InteropGate.Decision {
        guard item.state != .ready, let initialURL = item.url else { return .allowed }

        lock.lock()
        let alreadyRunning = inFlight.contains(item.id)
        if !alreadyRunning { inFlight.insert(item.id) }
        lock.unlock()
        guard !alreadyRunning else { return .allowed }
        defer {
            lock.lock()
            inFlight.remove(item.id)
            lock.unlock()
        }

        var item = item
        let url = initialURL

        // The ONE shared pipeline resolves wrappers, classifies, and processes every
        // URL. Its result carries the exact final URL, so this store is repointed
        // without independently repeating the unwrap work.
        let result = await IngestPipeline.processResolved(
            IngestInput(url: url, source: item.effectiveCaptureSource,
                        documentType: item.sanitizedDocumentType,
                        prefetchedHTML: prefetchedHTML, forceArticle: forceArticle,
                        trustsPrefetchedHTML: trustsPrefetchedHTML),
            fetcher: fetcher, extractor: extractor)

        let resolvedURL = result.url
        if resolvedURL != url {
            SharedDiagnosticLog.record(
                "ingest: unwrapped \(url.absoluteString) → \(resolvedURL.absoluteString)",
                category: "ingest")
            guard let updated = store.updateURL(resolvedURL.absoluteString, for: item.id) else {
                // The unwrapped article already exists in the list; wrapper dropped.
                return .allowed
            }
            item = updated
        }

        // Cross-app-interop gate — BEFORE the tracker-merge dedup below and before
        // the presenter, so a blocked outcome can neither merge into an existing
        // tracker nor write anything else. Exempt sources bypass entirely.
        let source = item.effectiveCaptureSource
        let interop: InteropGate.Decision = InteropGate.isGated(source: source)
            ? interopDecision(result.outcome)
            : .allowed
        if case let .blocked(owner, ownerInstalled) = interop {
            let urlString = resolvedURL.absoluteString
            await presentBlockedInterop(
                owner: owner, ownerInstalled: ownerInstalled, source: source,
                allowsInteractivePrompt: allowsInteractivePrompt,
                logMessage: "interop: blocked cross-app save (\(owner.storageIdentifier)) — discarded",
                discard: { store.delete(item) },
                retry: { Task { await ReadingListIngestor.shared.handleSavePress(
                    urlString: urlString, source: source) } })
            return interop
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
            postPriceTrackerSaved(itemID: existingTrackerItemID, source: item.effectiveCaptureSource,
                                  isMerge: true, highlightedURL: resolvedURL.absoluteString)
            return interop
        }

        let presenter = IngestorOutcomePresenter(ingestor: self, url: resolvedURL)
        await presenter.present(result.outcome, for: item)

        // Paid cross-surface save with the owning app missing: the save went
        // through exactly as always (above); interactive sources ALSO get the
        // informational "install Luna X" note.
        if case let .allowedNeedsInstall(owner) = interop,
           allowsInteractivePrompt, isInteractivePromptSource(source) {
            await MainActor.run {
                Self.interopPromptPresenter?(.needsInstall(owner: owner), nil)
            }
        }
        return interop
    }

    /// `.paste`/`.manual` are the only sources with a live UI able to show an interop
    /// prompt — App Intents get their own dialog from the intent layer, and
    /// background sweeps have no UI at all.
    private func isInteractivePromptSource(_ source: CaptureSource) -> Bool {
        source == .paste || source == .manual
    }

    /// Logs and, if eligible, presents the interop "blocked" prompt for a
    /// cross-app-gated save. `discard` runs first — `ingest` deletes the store
    /// placeholder it already created; `saveNewWithContent` calls this before ever
    /// adding one, so its `discard` is a no-op. Both call sites run this inline
    /// (never from a `defer`), so it can safely `await` the presenter.
    private func presentBlockedInterop(
        owner: InteropSurface, ownerInstalled: Bool, source: CaptureSource,
        allowsInteractivePrompt: Bool, logMessage: String, discard: () -> Void,
        retry: @escaping () -> Void
    ) async {
        discard()
        SharedDiagnosticLog.record(logMessage, category: "ingest")
        guard allowsInteractivePrompt, isInteractivePromptSource(source) else { return }
        await MainActor.run {
            Self.interopPromptPresenter?(.blocked(owner: owner, ownerInstalled: ownerInstalled), retry)
        }
    }

    // MARK: - Outcome handling (the main-app presenter, store-writing)

    /// Persists a readable article: downloads its images + cover art, saves the
    /// content, and flips ready.
    fileprivate func persistArticle(
        _ content: ArticleContent, html: String, for item: ReadingListItem, url: URL
    ) async {
        let contentWithCachedImages = ArticleImageDownloader.resolveLocalImages(content, store: store)
        let initialContent = await ArticleImageDownloader.downloadInitialLayoutImages(
            contentWithCachedImages, itemID: item.id, store: store, refererURL: url)
        // Persist reader content and flip the row to `.ready` FIRST — the reader is the
        // primary artifact and must not wait on non-visible remote image downloads,
        // row thumbnail fetches, or the (up-to-20s) web-archive capture. Only
        // unknown-size images near the top are fetched before readiness; known-size
        // images get stable placeholders and load later.
        let updated = store.saveContent(initialContent, for: item)
        if updated.state == .ready {
            ArticleSendCoordinator.shared.articleBecameReady(updated)
            // Background-preload this article's links so the inline link viewer opens
            // instantly. Non-blocking; no-op when the depth setting is 0.
            PreloadCoordinator.shared.preload(rootID: updated.id)
        }
        Task { [self] in
            await finishArticleArtifacts(
                initialContent, html: html, for: item, url: url)
        }
    }

    /// Finishes non-critical article artifacts after the row is already readable.
    /// This keeps ingestion latency tied to text extraction instead of remote media
    /// and WebKit archive capture.
    private func finishArticleArtifacts(
        _ content: ArticleContent, html: String, for item: ReadingListItem, url: URL
    ) async {
        async let downloadedContent = ArticleImageDownloader.download(
            content, itemID: item.id, store: store, refererURL: url)
        async let coverData = ArticleCoverThumbnail.coverImageData(html: html, baseURL: url)

        if let coverData = await coverData,
           store.item(withID: item.id)?.thumbnailFileName == nil {
            store.setThumbnail(coverData, for: item.id)
        }

        let resolvedContent = await downloadedContent
        if resolvedContent.blocks.contains(where: { $0.kind == .image && $0.imageFileName != nil }) {
            _ = store.saveContent(resolvedContent, for: item)
        }

        // Capture the unlocked HTML returned by the resolver. A fresh live navigation
        // can return the publisher's paywall even though this exact response produced
        // the complete native reader; live capture is only the fallback.
        await captureWebArchiveIfPossible(for: item, url: url, html: html)
    }

    /// Parks a paywalled article for the interactive archive reader.
    fileprivate func parkNeedsArchive(title: String, for item: ReadingListItem) async {
        store.markNeedsCaptcha(item.id, title: title)
    }

    /// Marks a genuine failure.
    fileprivate func markFailed(for item: ReadingListItem) async {
        store.markFailed(item.id)
    }

    /// Ingests a document outcome.
    fileprivate func handleDocument(type: String, for item: ReadingListItem) async {
        await ingestDocument(item)
    }

    /// Ingests a recognized video outcome.
    fileprivate func handleVideo(
        _ platform: ContentPlatform, itemID: String?, for item: ReadingListItem
    ) async {
        await ingestPlatformItem(
            item, match: PlatformMatch(platform: platform, itemID: itemID))
    }

    /// Ingests a recognized social platform outcome (best-effort metadata).
    fileprivate func handlePlatform(
        _ platform: ContentPlatform, itemID: String?, for item: ReadingListItem
    ) async {
        await ingestPlatformItem(
            item, match: PlatformMatch(platform: platform, itemID: itemID))
    }

    /// Turns a detected product page into a price tracker. Intelligent matching:
    /// if the product matches an existing tracker (by product id, else fuzzy
    /// name+brand), the new URL is MERGED into that tracker; otherwise a new
    /// tracker is created on this item.
    fileprivate func ingestProductTracker(
        _ item: ReadingListItem, url: URL, product: ProductInfo
    ) async {
        // Try to merge into an existing tracker for the same product.
        let existing: [(id: UUID, tracker: PriceTracker)] = store.items().compactMap {
            guard let tracker = $0.priceTracker, $0.id != item.id else { return nil }
            return ($0.id, tracker)
        }
        if let matchID = ProductMatcher.bestMatch(for: product, among: existing),
           var matched = store.item(withID: matchID)?.priceTracker {
            let stores = product.trackerStores(fallbackURL: url)
            let newStores = stores.filter { !matched.hasStore(urlString: $0.urlString) }
            guard !newStores.isEmpty else {
                store.delete(item)
                postPriceTrackerSaved(itemID: matchID, source: item.effectiveCaptureSource,
                                      isMerge: true, highlightedURL: stores.first?.urlString)
                return
            }
            for storeListing in newStores {
                matched.upsertStore(storeListing)
            }
            store.updatePriceTracker(matched, for: matchID)
            // The just-saved item was a duplicate route into an existing tracker;
            // drop its placeholder item so only the merged tracker remains.
            store.delete(item)
            postPriceTrackerSaved(itemID: matchID, source: item.effectiveCaptureSource,
                                  isMerge: true, highlightedURL: newStores.first?.urlString)
            return
        }

        var tracker = PriceTracker(
            productName: product.name, stores: product.trackerStores(fallbackURL: url),
            brand: product.brand, productID: product.productID)
        if let imageURL = product.imageURL,
           let data = await downloadProductImage(imageURL) {
            let fileName = "\(item.id.uuidString)-product.jpg"
            try? data.write(
                to: store.articlesDirectory.appendingPathComponent(fileName), options: .atomic)
            tracker.imageFileName = fileName
        }
        store.savePriceTracker(tracker, for: item.id)

        postPriceTrackerSaved(itemID: item.id, source: item.effectiveCaptureSource,
                              isMerge: false, highlightedURL: nil)
    }

    /// Announces a just-created/merged price tracker from an interactive in-app
    /// save (paste/manual) so the foreground list can present the price editor.
    /// App Intents, extensions, and background/friend saves must never trigger UI.
    private func postPriceTrackerSaved(
        itemID: UUID, source: CaptureSource, isMerge: Bool, highlightedURL: String?
    ) {
        switch source {
        case .paste, .manual:
            break
        case .appIntent, .shareSheet, .friendShare, .email:
            return
        }
        let userInfo: [String: Any] = [
            "itemID": itemID, "isMerge": isMerge,
            "highlightedURL": highlightedURL as Any,
        ]
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .priceTrackerSavedInteractively, object: nil, userInfo: userInfo)
        }
    }

    /// Downloads a product image. Returns nil on any failure.
    private func downloadProductImage(_ imageURL: URL) async -> Data? {
        var request = URLRequest(url: imageURL, timeoutInterval: 8)
        request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count > 512, data.count <= 5 * 1024 * 1024
        else { return nil }
        return data
    }

    /// Document ingestion: parse the imported file (stored at
    /// `Articles/<id>-source.<type>`) into article content. Documents are
    /// Kindle-eligible, so the becameReady hook runs as for web articles.
    private func ingestDocument(_ item: ReadingListItem) async {
        guard let type = item.sanitizedDocumentType else {
            store.markFailed(item.id)
            return
        }
        let sourceURL = store.articlesDirectory
            .appendingPathComponent("\(item.id.uuidString)-source.\(type)")
        guard let content = DocumentParser.parse(
            fileURL: sourceURL, type: type, title: item.title ?? "Document")
        else {
            store.markFailed(item.id)
            return
        }
        let updated = store.saveContent(content, for: item)
        if updated.state == .ready {
            ArticleSendCoordinator.shared.articleBecameReady(updated)
        }
    }

    /// Ingests a recognized platform item: best-effort metadata (title/creator/
    /// thumbnail via the module's optional fetcher), then marks `.ready`.
    /// Recognized platform items NEVER enter `.failed` — they render from a logo
    /// + deep link even when metadata is unavailable.
    private func ingestPlatformItem(_ item: ReadingListItem, match: PlatformMatch) async {
        let module = PlatformRegistry.shared.module(for: match.platform)
        let metadata = await module?.metadataFetcher?.fetchMetadata(
            for: match, urlString: item.urlString)

        var thumbnailFileName: String?
        if let data = metadata?.thumbnailData, !data.isEmpty {
            let fileName = "\(item.id.uuidString)-thumb.jpg"
            try? data.write(
                to: store.articlesDirectory.appendingPathComponent(fileName), options: .atomic)
            thumbnailFileName = fileName
        }

        _ = store.savePlatformMetadata(
            platform: match.platform,
            platformItemID: match.itemID,
            title: metadata?.title,
            creator: metadata?.creator,
            thumbnailFileName: thumbnailFileName,
            for: item.id)

        // Downloader normally uses the system-owned background job. App Intents
        // own their media handoff after the save result is known so the user's
        // setting can choose awaited file return or the same Live Activity path
        // without racing a second transfer from this ingestion task.
        if MediaAutoDownloader.isRunningInDownloader,
           item.effectiveCaptureSource != .appIntent {
            _ = await LiveMediaDownloadManager.shared.start(
                urlString: item.urlString, title: item.title, ownership: .downloader)
        } else if item.effectiveCaptureSource != .appIntent {
            await MediaAutoDownloader.runIfEnabledAwaiting(forURLString: item.urlString)
        }
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

    /// True while a thumbnail backfill pass is running, so overlapping
    /// `ingestAllPending()` calls (launch + foreground + pull-to-refresh) don't run
    /// duplicate cover fetches for the same items.
    @MainActor private var isBackfillingThumbnails = false
    /// Items whose thumbnail backfill was attempted-and-failed this session (no
    /// resolvable cover), so an un-coverable page isn't re-fetched on every pass.
    @MainActor private var thumbnailBackfillAttempted: Set<UUID> = []

    /// Repairs ready and locked web articles that have no row thumbnail — the
    /// action/share extension persists article content WITHOUT fetching the page's
    /// cover image (it's short-lived and sandbox-limited), and locked rows can often
    /// still expose `og:image` before unlock. This runs in the app process (full
    /// network) and brings them in line: a downloaded lead image is reused as-is,
    /// otherwise the page's `og:image` is fetched once. Idempotent — items that
    /// already have a thumbnail are skipped — so it also backfills any historical
    /// rows saved before thumbnails existed.
    public func backfillMissingThumbnails() {
        Task { @MainActor in
            guard !isBackfillingThumbnails else { return }
            isBackfillingThumbnails = true
            defer { isBackfillingThumbnails = false }

            let candidates = store.items().filter { item in
                (item.state == .ready || item.state == .needsCaptcha)
                    && item.thumbnailFileName == nil
                    && item.platform == nil                       // videos/platforms own their thumbnail
                    && item.priceTracker == nil                   // trackers own their image
                    && item.sanitizedDocumentType == nil          // documents have no cover
                    && !thumbnailBackfillAttempted.contains(item.id)
                    && (item.url?.scheme?.hasPrefix("http") ?? false)  // excludes lunamail:// / lunadoc://
            }
            // Cap per pass so a large backlog can't fire a burst of cover fetches.
            for item in candidates.prefix(12) {
                thumbnailBackfillAttempted.insert(item.id)
                await ArticleCoverThumbnail.backfillThumbnail(for: item, store: store)
            }
        }
    }

    /// True while a backfill pass is running, so overlapping `ingestAllPending()`
    /// calls (launch + pull-to-refresh) don't spin up a second fleet of web views.
    @MainActor private var isBackfillingArchives = false
    /// Items whose archive capture was attempted-and-failed this session, so we don't
    /// re-attempt an un-archivable page (which never gets a saved file, so it would
    /// otherwise re-enter the candidate set on every pass) on every refresh.
    @MainActor private var archiveBackfillAttempted: Set<UUID> = []

    /// `.webarchive` capture was added after many items were saved, and several save
    /// surfaces (extensions, paste, friend-share) don't capture inline. This repairs
    /// every ready web page that lacks an archive — one WebKit capture at a time so we
    /// never run a fleet of web views — which is also how those surfaces get covered.
    public func backfillMissingWebArchives() {
        Task { @MainActor in
            guard !isBackfillingArchives else { return }
            isBackfillingArchives = true
            defer { isBackfillingArchives = false }

            let candidates = store.items().filter { item in
                item.state == .ready
                    && item.sanitizedDocumentType == nil          // documents already have a source file
                    && store.webArchiveURL(for: item) == nil
                    && !archiveBackfillAttempted.contains(item.id)  // don't retry a failed page forever
                    && (URL(string: item.urlString)?.scheme?.hasPrefix("http") ?? false)  // excludes lunamail://
            }
            // Cap per pass so a large backlog doesn't tie up a web view indefinitely.
            for item in candidates.prefix(8) {
                guard let url = URL(string: item.urlString) else { continue }
                archiveBackfillAttempted.insert(item.id)
                await captureWebArchiveIfPossible(for: item, url: url, html: nil)
            }
        }
    }

    /// Captures and stores a cleaned `.webarchive`, preferring the resolver's exact
    /// unlocked HTML over a fresh live navigation that may reintroduce a paywall.
    fileprivate func captureWebArchiveIfPossible(for item: ReadingListItem, url: URL, html: String?) async {
        guard url.scheme?.hasPrefix("http") ?? false else { return }   // never for lunamail://, lunadoc://
        var archive: Data?
        if let html, !html.isEmpty {
            archive = await WebArchiveCapturer.capture(html: html, baseURL: url)
        }
        if archive == nil {
            archive = await WebArchiveCapturer.capture(url: url)
        }
        if let archive { store.saveWebArchive(archive, for: item) }
    }

    /// What a save press did, so intents can wait on the right work.
    public enum SavePressResult {
        /// New URL — saved; ingestion may still be running.
        case saved(ReadingListItem)
        /// New URL — saved, and the classified outcome belongs to `owner`,
        /// whose app isn't installed (paid cross-surface save). Callers with a
        /// dialog surface (the Save App Intent) mention installing `owner`.
        case savedNeedsOwnerInstall(ReadingListItem, owner: InteropSurface)
        /// New URL whose classified outcome belongs to a DIFFERENT Luna app and
        /// the interop unlock isn't purchased: the item was DISCARDED — nothing
        /// remains in the store (`claudedocs/interop-purchase.md`). Interactive
        /// in-app saves have already shown the interop prompt by the time this
        /// returns; the Save App Intent turns it into an error dialog.
        case blockedByInterop(owner: InteropSurface, ownerInstalled: Bool)
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
    }

    /// The save-press entry point shared by the intents and the in-app add:
    /// first press saves and ingests; a second press within a few seconds
    /// triggers the configured double-save behavior; any other press on an
    /// existing URL is ignored. Awaits the resulting work (callers bound it
    /// with a timeout).
    ///
    /// `doubleSaveActionSurface`: non-nil ONLY for saves arriving through the
    /// Action Button's Save App Intent on a surface with the double-save action
    /// enabled (today: Reader). It carries the surface's storage identifier and
    /// switches a repeat press into the 7 s configured-action regime
    /// (`DoubleSaveActionStore`) instead of the legacy ereader double save.
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
            doubleSaveDestinationIDs: ArticleSendCoordinator.shared.doubleSaveDestinationIDs(),
            intentAction: doubleSaveActionSurface.flatMap(Self.resolvedIntentAction(forSurface:)))

        switch decision {
        case .saveNew:
            let item = store.add(urlString: urlString, source: source)
            if source == .appIntent && interopGateCannotFire {
                // Persist and return the URL promptly. Extraction/classification is
                // best-effort background work and must not consume the intent budget.
                // Only when the interop gate can't possibly fire (unlocked + every
                // sibling app installed): otherwise the intent must WAIT for the
                // classified outcome so a blocked save can surface an error dialog
                // instead of silently discarding — the intent layer's own 12 s
                // race still bounds the wait (a timed-out blocked save is then
                // discarded by the gate in the background, dialog-less but
                // store-consistent).
                Task { await self.ingest(item, prefetchedHTML: prefetchedHTML,
                                         trustsPrefetchedHTML: trustsPrefetchedHTML) }
                return .saved(item)
            }
            let interop = await ingest(item, prefetchedHTML: prefetchedHTML,
                                       trustsPrefetchedHTML: trustsPrefetchedHTML)
            switch interop {
            case let .blocked(owner, ownerInstalled):
                return .blockedByInterop(owner: owner, ownerInstalled: ownerInstalled)
            case let .allowedNeedsInstall(owner):
                return .savedNeedsOwnerInstall(store.item(withID: item.id) ?? item, owner: owner)
            case .allowed:
                return .saved(item)
            }
        case .sendToEreaders(let destinationIDs):
            // The policy only returns this for an existing item.
            guard let existing else { return .ignored }
            for destinationID in destinationIDs {
                await ArticleSendCoordinator.shared.send(existing, toDestinationID: destinationID)
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

    /// True when the interop gate can't produce anything but `.allowed` for a
    /// gated source: the unlock is purchased AND every Luna app is installed
    /// (so `.allowedNeedsInstall` is impossible too). Lets the App Intent save
    /// keep its fast persist-and-return path in the steady state.
    private var interopGateCannotFire: Bool {
        // Same inputs the injected `interopDecision` defaults to; kept separate
        // because this is a pre-classification shortcut, not a decision.
        InteropEntitlement.shared.isUnlocked
            && InteropSurface.allCases.allSatisfy(\.isInstalled)
    }

    /// Resolves the configured double-save action into the policy's pure input,
    /// applying the configuration checks the policy itself can't know about.
    /// nil ⇒ the action can't run right now (e.g. Kindle not configured), so a
    /// repeat press falls back to being ignored.
    private static func resolvedIntentAction(
        forSurface surface: String
    ) -> SavePressPolicy.IntentAction? {
        let store = DoubleSaveActionStore.shared
        switch store.action(forSurface: surface) {
        case .sendToKindle:
            guard ArticleSendCoordinator.shared.isConfigured(
                destinationID: ArticleDestinationID.kindle) else { return nil }
            return .sendToKindle
        case .sendToFriend:
            // Preset recipients need a configured sharing account to actually
            // send; without one (or without any preset picked yet) fall back to
            // the in-app selector, which guides account setup itself.
            guard store.friendMode(forSurface: surface) == .preset else {
                return .promptFriendSelector
            }
            let emails = store.presetFriendEmails(forSurface: surface).filter {
                !FriendsStore.shared.isBlocked($0)
            }
            guard !emails.isEmpty, EmailShareCenter.shared.isConfigured else {
                return .promptFriendSelector
            }
            return .sendToFriends(emails: emails)
        }
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
    /// The direct-persist fast path bypasses `ingest`, so the interop gate runs
    /// here explicitly: the pre-fetched content IS the classified outcome (an
    /// article — Reader-owned), so a blocked cross-surface paste is refused
    /// before anything is added, with the same interactive prompt.
    @discardableResult
    public func saveNewWithContent(
        urlString: String, content: ArticleContent, source: CaptureSource = .manual
    ) async -> ReadingListItem? {
        guard let url = URLUnwrapper.ingestURL(from: urlString) else { return nil }
        let urlString = url.absoluteString

        let interop: InteropGate.Decision = InteropGate.isGated(source: source)
            ? interopDecision(.article(content, html: ""))
            : .allowed
        if case let .blocked(owner, ownerInstalled) = interop {
            await presentBlockedInterop(
                owner: owner, ownerInstalled: ownerInstalled, source: source,
                allowsInteractivePrompt: true,
                logMessage: "interop: blocked cross-app paste save (reader) — refused",
                discard: {},
                retry: { Task { await ReadingListIngestor.shared.saveNewWithContent(
                    urlString: urlString, content: content, source: source) } })
            return nil
        }

        let item = store.add(urlString: urlString, source: source)
        defer {
            if case let .allowedNeedsInstall(owner) = interop,
               isInteractivePromptSource(source) {
                Task { @MainActor in
                    Self.interopPromptPresenter?(.needsInstall(owner: owner), nil)
                }
            }
        }
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
            ArticleSendCoordinator.shared.articleBecameReady(saved)
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
        case .failed:
            await ingestor.markFailed(for: item)
        }
    }
}
