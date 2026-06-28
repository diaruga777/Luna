//
//  ReadingListIngestor.swift
//  Clip
//

import ClipYouTubeAPI
import ClipReaderUI
import ClipArchiveReader
import ClipSemantic
import ClipSocial
import ClipMediaDownload
import ClipPlatforms
import ClipSend
import ClipDocuments
import ClipStorage
import ClipIngest
import ClipFetch
import ClipHTMLClassification
import ClipURLClassification
import ClipModels
import Foundation

/// Downloads and extracts content for reading-list items: the immediate step
/// after a link is saved, plus a retry pass for anything still pending.
public final class ReadingListIngestor {
    public static let shared = ReadingListIngestor()

    private let store = ReadingListStore.shared
    private let fetcher = ArticleFetcher()
    private let extractor = ArticleExtractor()
    private let youTubeMetadataFetcher: YouTubeMetadataFetching = YouTubeOEmbedFetcher()
    /// Records a `Replay` for each save (diagnostics). `NoopReplayRecorder` keeps
    /// recording off the hot path optional — a save runs identically without it.
    private let recorder: ReplayRecording

    public init(recorder: ReplayRecording = ReplayRecorder.shared) {
        self.recorder = recorder
    }

    /// IDs currently being ingested, to avoid duplicate concurrent work.
    private var inFlight = Set<UUID>()
    private let lock = NSLock()

    /// Fetches and extracts content for one item. Safe to call repeatedly.
    ///
    /// `forceArticle` skips product-page detection entirely, so the URL is ingested
    /// as a normal article even if its page would otherwise be classified as a price
    /// tracker. Used by the "Read instead" override on the price-tracking editor.
    public func ingest(_ item: ReadingListItem, forceArticle: Bool = false) async {
        guard item.state != .ready, let initialURL = item.url else { return }

        lock.lock()
        let alreadyRunning = inFlight.contains(item.id)
        if !alreadyRunning { inFlight.insert(item.id) }
        lock.unlock()
        guard !alreadyRunning else { return }
        defer {
            lock.lock()
            inFlight.remove(item.id)
            lock.unlock()
        }

        // Start a diagnostic replay for this save (no-op if recording is disabled).
        // Every save entry point that reaches `ingest` (intents, paste, manual,
        // in-app add) is covered by this single seam.
        let replayID = await recorder.begin(
            urlString: initialURL.absoluteString,
            source: .capture(item.effectiveCaptureSource))
        if let replayID { await recorder.attachItemID(item.id, to: replayID) }

        var item = item
        let url = initialURL

        // The fetcher is wrapped so every request/response is captured into the replay.
        let resolveFetcher: HTMLFetching = replayID
            .map { RecordingHTMLFetcher(wrapping: fetcher, recorder: recorder, replayID: $0) }
            ?? fetcher

        // The ONE shared pipeline resolves wrappers, classifies, and processes every
        // URL. Its result carries the exact final URL, so this store is repointed
        // without independently repeating the unwrap work.
        let result = await IngestPipeline.processResolved(
            IngestInput(url: url, source: item.effectiveCaptureSource,
                        documentType: item.sanitizedDocumentType, forceArticle: forceArticle),
            fetcher: resolveFetcher, extractor: extractor,
            replayLog: replayID.map { id in { [recorder] event in await recorder.record(event, for: id) } })

        let resolvedURL = result.url
        if resolvedURL != url {
            SharedDiagnosticLog.record(
                "ingest: unwrapped \(url.absoluteString) → \(resolvedURL.absoluteString)",
                category: "ingest")
            guard let updated = store.updateURL(resolvedURL.absoluteString, for: item.id) else {
                // The unwrapped article already exists in the list; wrapper dropped.
                if let replayID {
                    await recorder.record(.note("unwrapped URL already saved; dropped"), for: replayID)
                    await recorder.terminate(replayID, state: .failed, finalContent: nil)
                }
                return
            }
            item = updated
            if let replayID { await recorder.updateItemURL(resolvedURL.absoluteString, for: replayID) }
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
            if let replayID {
                await recorder.record(
                    .note("url already tracked by \(existingTrackerItemID); dropped duplicate"),
                    for: replayID)
                await recorder.terminate(replayID, state: .success, finalContent: nil)
            }
            postPriceTrackerSaved(itemID: existingTrackerItemID, source: item.effectiveCaptureSource,
                                  isMerge: true, highlightedURL: resolvedURL.absoluteString)
            return
        }

        let presenter = IngestorOutcomePresenter(ingestor: self, url: resolvedURL, replayID: replayID)
        await presenter.present(result.outcome, for: item)
    }

    // MARK: - Outcome handling (the main-app presenter, store-writing)

    /// Persists a readable article: downloads its images + cover art, saves the
    /// content, flips ready, and terminates the replay `.success`.
    fileprivate func persistArticle(
        _ content: ArticleContent, html: String, for item: ReadingListItem, url: URL, replayID: UUID?
    ) async {
        if let replayID {
            await recorder.record(.resolveDecision(.readable), for: replayID)
            await recorder.record(.extraction(
                blockCount: content.blocks.count, bodyTextLength: content.bodyTextLength,
                title: content.title, hasReadableBody: content.hasReadableBody), for: replayID)
        }
        let resolvedContent = await ArticleImageDownloader.download(
            content, itemID: item.id, store: store, refererURL: url)
        let coverData = await fetchCoverImageData(html: html, baseURL: url)
        // Persist reader content and flip the row to `.ready` FIRST — the reader is the
        // primary artifact and must not wait on the (up-to-20s) web-archive capture, or
        // a time-bounded save intent (e.g. the Kindle double-press) could miss its
        // deadline. The archive is a "nice to have original", captured after.
        let updated = store.saveContent(resolvedContent, for: item)
        if let coverData { store.setThumbnail(coverData, for: item.id) }
        if updated.state == .ready {
            ArticleSendCoordinator.shared.articleBecameReady(updated)
            // Background-preload this article's links so the inline link viewer opens
            // instantly. Non-blocking; no-op when the depth setting is 0.
            PreloadCoordinator.shared.preload(rootID: updated.id)
        }
        if let replayID {
            await recorder.terminate(replayID, state: .success, finalContent: resolvedContent)
        }
        // Capture the original page now that the reader is ready. Prefer a live URL
        // navigation (WebKit fetches every subresource, so Original renders like the
        // real page); fall back to the fetched HTML only if that fails.
        await captureWebArchiveIfPossible(for: item, url: url, html: html)
    }

    /// Parks a paywalled article for the interactive archive reader. NOT terminal for
    /// the replay — the web reader owns its own.
    fileprivate func parkNeedsArchive(title: String, for item: ReadingListItem, replayID: UUID?) async {
        store.markNeedsCaptcha(item.id, title: title)
        if let replayID {
            await recorder.record(.resolveDecision(.paywalled), for: replayID)
            await recorder.terminate(replayID, state: .failed, finalContent: nil)
        }
    }

    /// Marks a genuine failure and terminates the replay `.failed`.
    fileprivate func markFailed(for item: ReadingListItem, replayID: UUID?) async {
        store.markFailed(item.id)
        if let replayID {
            await recorder.record(.resolveDecision(.unreadable), for: replayID)
            await recorder.terminate(replayID, state: .failed, finalContent: nil)
        }
    }

    /// Ingests a document outcome, recording + terminating the replay.
    fileprivate func handleDocument(type: String, for item: ReadingListItem, replayID: UUID?) async {
        await ingestDocument(item)
        if let replayID {
            await recorder.record(.note("document ingest (\(type))"), for: replayID)
            await recorder.terminate(
                replayID, state: store.item(withID: item.id)?.state == .ready ? .success : .failed,
                finalContent: nil)
        }
    }

    /// Ingests a recognized YouTube video outcome (best-effort metadata).
    fileprivate func handleVideo(itemID: String?, for item: ReadingListItem, replayID: UUID?) async {
        if let videoID = itemID {
            await ingestYouTubeVideo(item, videoID: videoID)
        } else {
            store.markFailed(item.id)
        }
        await terminateNonArticle(replayID, itemID: item.id, note: "youtube video \(itemID ?? "?")")
    }

    /// Ingests a recognized social/audio platform outcome (best-effort metadata).
    fileprivate func handlePlatform(
        _ platform: ContentPlatform, service: MusicProvider?, itemID: String?,
        for item: ReadingListItem, replayID: UUID?
    ) async {
        await ingestPlatformItem(
            item, match: PlatformMatch(platform: platform, itemID: itemID, sourceService: service))
        await terminateNonArticle(replayID, itemID: item.id, note: "platform \(platform)")
    }

    /// Terminates the replay for a non-article item (video/platform): these never
    /// `.fail`, so success reflects whether the item ended `.ready`. Media art is
    /// recorded by reference only (never bytes) before terminating.
    private func terminateNonArticle(_ replayID: UUID?, itemID: UUID, note: String) async {
        guard let replayID else { return }
        await recorder.record(.note(note), for: replayID)
        if let item = store.item(withID: itemID), let thumbnail = item.thumbnailFileName {
            await recorder.record(.mediaReference(role: "thumbnail", urlString: thumbnail), for: replayID)
        }
        let ready = store.item(withID: itemID)?.state == .ready
        await recorder.terminate(replayID, state: ready ? .success : .failed, finalContent: nil)
    }

    /// Turns a detected product page into a price tracker. Intelligent matching:
    /// if the product matches an existing tracker (by product id, else fuzzy
    /// name+brand), the new URL is MERGED into that tracker; otherwise a new
    /// tracker is created on this item. Records the product-detection decision and
    /// the per-URL price fetch into the replay, terminating `.success`.
    fileprivate func ingestProductTracker(
        _ item: ReadingListItem, url: URL, product: ProductInfo, replayID: UUID?
    ) async {
        if let replayID {
            await recorder.record(
                .note("product detected: \(product.name) \(product.priceCurrency) "
                      + "\(NSDecimalNumber(decimal: product.priceAmount).stringValue)"),
                for: replayID)
        }

        // Try to merge into an existing tracker for the same product.
        let existing: [(id: UUID, tracker: PriceTracker)] = store.items().compactMap {
            guard let tracker = $0.priceTracker, $0.id != item.id else { return nil }
            return ($0.id, tracker)
        }
        if let matchID = ProductMatcher.bestMatch(for: product, among: existing),
           var matched = store.item(withID: matchID)?.priceTracker,
           !matched.hasStore(urlString: url.absoluteString) {
            matched.upsertStore(PriceTrackerStore(
                urlString: url.absoluteString, lastPrice: product.priceAmount,
                currency: product.priceCurrency, lastRefreshed: Date()))
            store.updatePriceTracker(matched, for: matchID)
            // The just-saved item was a duplicate route into an existing tracker;
            // drop its placeholder item so only the merged tracker remains.
            store.delete(item)
            if let replayID {
                await recorder.record(.note("merged into existing tracker \(matchID)"), for: replayID)
                if let imageURL = product.imageURL {
                    await recorder.record(
                        .mediaReference(role: "productImage", urlString: imageURL.absoluteString),
                        for: replayID)
                }
                await recorder.terminate(replayID, state: .success, finalContent: nil)
            }
            postPriceTrackerSaved(itemID: matchID, source: item.effectiveCaptureSource,
                                  isMerge: true, highlightedURL: url.absoluteString)
            return
        }

        var tracker = PriceTracker(
            productName: product.name, firstStoreURL: url.absoluteString,
            price: product.priceAmount, currency: product.priceCurrency,
            brand: product.brand, productID: product.productID)
        if let imageURL = product.imageURL,
           let data = await downloadProductImage(imageURL) {
            let fileName = "\(item.id.uuidString)-product.jpg"
            try? data.write(
                to: store.articlesDirectory.appendingPathComponent(fileName), options: .atomic)
            tracker.imageFileName = fileName
        }
        store.savePriceTracker(tracker, for: item.id)

        if let replayID {
            await recorder.record(.note("created price tracker"), for: replayID)
            if let imageURL = product.imageURL {
                await recorder.record(
                    .mediaReference(role: "productImage", urlString: imageURL.absoluteString),
                    for: replayID)
            }
            await recorder.terminate(replayID, state: .success, finalContent: nil)
        }
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

    /// Downloads a product image (by reference only in the replay; bytes never
    /// recorded). Returns nil on any failure.
    private func downloadProductImage(_ imageURL: URL) async -> Data? {
        var request = URLRequest(url: imageURL, timeoutInterval: 8)
        request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count > 512, data.count <= 5 * 1024 * 1024
        else { return nil }
        return data
    }

    /// Downloads an article's cover image (og:image / twitter:image) with a short
    /// timeout. Returns nil on any failure — the row then shows no thumbnail.
    private func fetchCoverImageData(html: String, baseURL: URL) async -> Data? {
        guard let imageURL = LeadImageExtractor.imageURL(in: html, baseURL: baseURL) else { return nil }
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

    /// Video ingestion: oEmbed title/channel + thumbnail download; no article
    /// content. On first readiness, the watch-later auto-add hook runs (never
    /// for repeat presses — duplicates don't re-ingest).
    private func ingestYouTubeVideo(_ item: ReadingListItem, videoID: String) async {
        do {
            let metadata = try await youTubeMetadataFetcher.fetchMetadata(videoID: videoID)
            var thumbnailFileName: String?
            if let thumbnail = try? await youTubeMetadataFetcher.fetchThumbnail(videoID: videoID) {
                let fileName = "\(item.id.uuidString)-thumb.jpg"
                try? thumbnail.write(
                    to: store.articlesDirectory.appendingPathComponent(fileName),
                    options: .atomic)
                thumbnailFileName = fileName
            }
            guard let updated = store.saveYouTubeMetadata(
                videoID: videoID, title: metadata.title,
                channelName: metadata.channelName,
                thumbnailFileName: thumbnailFileName, for: item.id)
            else { return }
            await WatchLaterAutoAdder.shared.videoBecameReady(updated)
            // YouTube suggestion streaks key on the CHANNEL, which is only known
            // now (post-oEmbed) — so the streak/auto-share check runs here, not
            // at save time (where handleNewSave saw no channel and no-oped).
            let autoShareTargets = ShareSuggestionStore.shared.handleNewSave(
                urlString: updated.urlString, channelName: metadata.channelName)
            for target in autoShareTargets {
                await SocialMessageCenter.shared.autoShare(
                    urlString: updated.urlString, toFriendUUID: target.uuid)
            }
        } catch {
            store.markFailed(item.id)
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
            mediaCreatorName: metadata?.mediaCreatorName,
            mediaItemTitle: metadata?.mediaItemTitle,
            mediaSourceService: match.sourceService,
            for: item.id)

        // Auto-download the post's media to Photos when enabled for this platform.
        // Awaited so an app intent finishes the download before it returns; dedup'd
        // so it never double-saves a post already downloaded by the share extension.
        await MediaAutoDownloader.runIfEnabledAwaiting(forURLString: item.urlString)
    }

    /// Kicks off ingestion for everything not yet ready (app launch / foreground).
    public func ingestAllPending() {
        // `.needsCaptcha` items can only advance when the user solves the archive
        // CAPTCHA, so a background re-fetch can't help them — retry only the states
        // that an automated pass can actually move forward.
        for item in store.items() where item.state == .pending || item.state == .failed {
            Task { await self.ingest(item) }
        }
        backfillMissingWebArchives()
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
                    && (URL(string: item.urlString)?.scheme?.hasPrefix("http") ?? false)  // excludes clipmail://
            }
            // Cap per pass so a large backlog doesn't tie up a web view indefinitely.
            for item in candidates.prefix(8) {
                guard let url = URL(string: item.urlString) else { continue }
                archiveBackfillAttempted.insert(item.id)
                await captureWebArchiveIfPossible(for: item, url: url, html: nil)
            }
        }
    }

    /// Captures and stores a `.webarchive` for a web page, preferring the live URL.
    fileprivate func captureWebArchiveIfPossible(for item: ReadingListItem, url: URL, html: String?) async {
        guard url.scheme?.hasPrefix("http") ?? false else { return }   // never for clipmail://, clipdoc://
        var archive = await WebArchiveCapturer.capture(url: url)
        if archive == nil, let html, !html.isEmpty {
            archive = await WebArchiveCapturer.capture(html: html, baseURL: url)
        }
        if let archive { store.saveWebArchive(archive, for: item) }
    }

    /// What a save press did, so intents can wait on the right work.
    public enum SavePressResult {
        /// New URL — saved; ingestion may still be running.
        case saved(ReadingListItem)
        /// Double press — the article was (re)sent to one or more ereaders.
        case sentToEreaders(ReadingListItem)
        /// Duplicate press — nothing happened.
        case ignored
    }

    /// The save-press entry point shared by the intents and the in-app add:
    /// first press saves and ingests; a second press within a few seconds sends
    /// the article to Kindle (when configured); any other press on an existing
    /// URL is ignored. Awaits the resulting work (callers bound it with a timeout).
    @discardableResult
    public func handleSavePress(urlString: String, source: CaptureSource = .manual) async -> SavePressResult {
        guard let url = URLUnwrapper.ingestURL(from: urlString) else { return .ignored }
        let urlString = url.absoluteString
        let existing = store.item(forURLString: urlString)
        let previousPress = existing.map { store.recordSaveAttempt(for: $0.id) } ?? nil

        let decision = SavePressPolicy.decide(
            existingItem: existing,
            previousPressDate: previousPress,
            now: Date(),
            doubleSaveDestinationIDs: ArticleSendCoordinator.shared.doubleSaveDestinationIDs())

        switch decision {
        case .saveNew:
            let item = store.add(urlString: urlString, source: source)
            // New-save automation runs HERE and only here — repeat presses
            // (e.g. double-save for Kindle) never re-share or re-suggest.
            fireAutoShares(urlString: urlString)
            await ingest(item)
            armSemanticSuggestionIfNeeded(urlString: urlString, itemID: item.id)
            return .saved(item)
        case .sendToEreaders(let destinationIDs):
            // The policy only returns this for an existing item.
            guard let existing else { return .ignored }
            for destinationID in destinationIDs {
                await ArticleSendCoordinator.shared.send(existing, toDestinationID: destinationID)
            }
            return .sentToEreaders(existing)
        case .ignore:
            return .ignored
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
    /// Runs the same new-save automation as a fresh save press.
    @discardableResult
    public func saveNewWithContent(
        urlString: String, content: ArticleContent, source: CaptureSource = .manual
    ) async -> ReadingListItem? {
        guard let url = URLUnwrapper.ingestURL(from: urlString) else { return nil }
        let urlString = url.absoluteString
        let item = store.add(urlString: urlString, source: source)
        fireAutoShares(urlString: urlString)
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
        armSemanticSuggestionIfNeeded(urlString: urlString, itemID: item.id)
        return saved
    }

    /// Auto-shares a newly saved URL to every friend the user set to always
    /// receive that site.
    private func fireAutoShares(urlString: String) {
        let autoShareTargets = ShareSuggestionStore.shared.handleNewSave(urlString: urlString)
        for target in autoShareTargets {
            Task {
                await SocialMessageCenter.shared.autoShare(
                    urlString: urlString, toFriendUUID: target.uuid)
            }
        }
    }

    /// Arms the immediate content-similarity suggestion (one embed of just this
    /// item) — only when no same-site/-channel streak already armed one.
    private func armSemanticSuggestionIfNeeded(urlString: String, itemID: UUID) {
        guard ShareSuggestionStore.shared.pendingSuggestion() == nil,
              let match = SemanticIndexer.shared.immediateSuggestion(forItemID: itemID)
        else { return }
        ShareSuggestionStore.shared.armSemanticSuggestion(
            urlString: urlString, friendUUID: match.uuid, friendUsername: match.username)
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
    public let replayID: UUID?

    public func present(_ outcome: Outcome, for item: ReadingListItem) async {
        switch outcome {
        case let .article(content, html):
            await ingestor.persistArticle(content, html: html, for: item, url: url, replayID: replayID)
        case let .product(product, _):
            await ingestor.ingestProductTracker(item, url: url, product: product, replayID: replayID)
        case let .video(_, itemID):
            await ingestor.handleVideo(itemID: itemID, for: item, replayID: replayID)
        case let .social(platform, itemID):
            await ingestor.handlePlatform(platform, service: nil, itemID: itemID, for: item, replayID: replayID)
        case let .audio(platform, service, itemID):
            await ingestor.handlePlatform(platform, service: service, itemID: itemID, for: item, replayID: replayID)
        case let .document(type):
            await ingestor.handleDocument(type: type, for: item, replayID: replayID)
        case let .needsArchive(title):
            await ingestor.parkNeedsArchive(title: title, for: item, replayID: replayID)
        case .failed:
            await ingestor.markFailed(for: item, replayID: replayID)
        }
    }
}
