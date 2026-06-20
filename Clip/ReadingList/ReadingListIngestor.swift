//
//  ReadingListIngestor.swift
//  Clip
//

import Foundation

/// Downloads and extracts content for reading-list items: the immediate step
/// after a link is saved, plus a retry pass for anything still pending.
final class ReadingListIngestor {
    static let shared = ReadingListIngestor()

    private let store = ReadingListStore.shared
    private let fetcher = ArticleFetcher()
    private let extractor = ArticleExtractor()
    private let youTubeMetadataFetcher: YouTubeMetadataFetching = YouTubeOEmbedFetcher()
    private let productDetector = ProductPageDetector()
    /// Resolves the mandatory price for a detected product (static → embedded JSON
    /// → WKWebView render). A product never becomes a tracker without a real price.
    private let priceFetcher: PriceFetching = PriceFetcher()
    /// Records a `Replay` for each save (diagnostics). `NoopReplayRecorder` keeps
    /// recording off the hot path optional — a save runs identically without it.
    private let recorder: ReplayRecording

    init(recorder: ReplayRecording = ReplayRecorder.shared) {
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
    func ingest(_ item: ReadingListItem, forceArticle: Bool = false) async {
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

        // Unwrap news-aggregator wrappers (Apple News, Google News, link
        // shorteners) to the real publisher article BEFORE anything else, then
        // continue as if that had been saved — both extraction and the
        // archive.today reader need the real URL, not the wrapper. Non-wrapper
        // URLs return immediately (no network).
        var item = item
        var url = initialURL
        if let unwrapped = await NewsAggregatorUnwrapper.unwrap(initialURL),
           unwrapped.absoluteString != initialURL.absoluteString {
            SharedDiagnosticLog.record(
                "ingest: unwrapped \(initialURL.absoluteString) → \(unwrapped.absoluteString)",
                category: "ingest")
            if let replayID {
                await recorder.record(
                    .unwrap(fromURLString: initialURL.absoluteString,
                            toURLString: unwrapped.absoluteString), for: replayID)
            }
            guard let updated = store.updateURL(unwrapped.absoluteString, for: item.id) else {
                // The unwrapped article already exists in the list; wrapper dropped.
                if let replayID {
                    await recorder.record(.note("unwrapped URL already saved; dropped"), for: replayID)
                    await recorder.terminate(replayID, state: .failed, finalContent: nil)
                }
                return
            }
            item = updated
            url = updated.url ?? unwrapped
            if let replayID { await recorder.updateItemURL(url.absoluteString, for: replayID) }
        }

        if item.isDocument {
            await ingestDocument(item)
            if let replayID {
                await recorder.record(.note("document ingest (\(item.sanitizedDocumentType ?? "?"))"),
                                      for: replayID)
                await recorder.terminate(
                    replayID, state: store.item(withID: item.id)?.state == .ready ? .success : .failed,
                    finalContent: nil)
            }
            return
        }

        if let videoID = YouTubeURL.videoID(from: item.urlString) {
            await ingestYouTubeVideo(item, videoID: videoID)
            await terminateNonArticle(replayID, itemID: item.id, note: "youtube video \(videoID)")
            return
        }

        // A recognized platform URL (X, Bluesky, …) is accepted as a no-content
        // item — NEVER run through the article extractor (which would fail and
        // mark it "Couldn't Load").
        if let match = PlatformRegistry.shared.detect(item.urlString) {
            await ingestPlatformItem(item, match: match)
            await terminateNonArticle(replayID, itemID: item.id, note: "platform \(match.platform)")
            return
        }

        // Re-save dedup BEFORE any (re)detection: if this exact URL is already a
        // store inside an existing price tracker, it was already classified as
        // price-tracking on a previous save. Re-running detection could reach a
        // different outcome (UA/render variance) and a re-merge would no-op into a
        // duplicate tracker — so short-circuit to the existing tracker deterministically.
        // This is the merge path's re-save (the placeholder item was deleted on the
        // first merge, so `item(forURLString:)` misses and a fresh placeholder arrives
        // here). A NEW (un-merged) tracker keeps its item `.ready`, so `ingest`'s
        // top guard already prevents re-detection for that case.
        if !forceArticle,
           let (existingTrackerItemID, _) = store.priceTracker(containingStoreURL: url.absoluteString),
           existingTrackerItemID != item.id {
            store.delete(item)
            if let replayID {
                await recorder.record(
                    .note("url already tracked by \(existingTrackerItemID); dropped duplicate"),
                    for: replayID)
                await recorder.terminate(replayID, state: .success, finalContent: nil)
            }
            postPriceTrackerSaved(itemID: existingTrackerItemID, source: item.effectiveCaptureSource,
                                  isMerge: true, highlightedURL: url.absoluteString)
            return
        }

        // The fetcher is wrapped so every request/response is captured into the replay.
        let resolveFetcher: HTMLFetching = replayID
            .map { RecordingHTMLFetcher(wrapping: fetcher, recorder: recorder, replayID: $0) }
            ?? fetcher

        // Product-page detection runs BEFORE any paywall/archive treatment: a
        // product page becomes a PRICE TRACKER, never an article and never the
        // bypass/archive flow. Detection identifies a product CANDIDATE; the price
        // is then fetched up front (static → embedded JSON → WKWebView render). Only
        // a candidate with a real fetched price becomes a tracker — if no price can
        // be obtained by any method, the candidate falls through to the normal
        // article pipeline (saved as a plain article, never a broken tracker).
        let productHTML = forceArticle ? nil : try? await resolveFetcher.fetchHTML(from: url)
        if let html = productHTML,
           let candidate = productDetector.detect(urlString: url.absoluteString, html: html) {
            if let price = await priceFetcher.fetchPrice(
                forURLString: url.absoluteString, prefetchedHTML: html) {
                let product = ProductInfo(candidate: candidate, price: price)
                await ingestProductTracker(item, url: url, product: product, replayID: replayID)
                return
            }
            if let replayID {
                await recorder.record(
                    .note("product candidate \(candidate.name) had no fetchable price → article"),
                    for: replayID)
            }
        }

        // Direct fetch + extract, falling back to web archives for hard-paywalled
        // sites (WSJ: 401; FT: subscription stub). A paywall whose body we can't
        // read but whose title we can lands in `.needsCaptcha` — the archive.today
        // snapshot it needs requires a user-solved CAPTCHA a background fetch can't
        // pass, so the user unlocks it from the list. No title → genuinely broken.
        let resolution = await ArticleResolver.resolve(
            url: url, fetcher: resolveFetcher, extractor: extractor,
            replayLog: replayID.map { id in { [recorder] event in await recorder.record(event, for: id) } })
        switch resolution {
        case .readable(let content, let html):
            if let replayID {
                await recorder.record(.resolveDecision(.readable), for: replayID)
                await recorder.record(.extraction(
                    blockCount: content.blocks.count, bodyTextLength: content.bodyTextLength,
                    title: content.title, hasReadableBody: content.hasReadableBody), for: replayID)
            }
            let resolvedContent = await downloadImages(for: content, itemID: item.id)
            // Best-effort cover/banner art for the list row (kept before the
            // ready flip so the row's spinner covers the whole fetch).
            let coverData = await fetchCoverImageData(html: html, baseURL: url)
            let updated = store.saveContent(resolvedContent, for: item)
            if let coverData { store.setThumbnail(coverData, for: item.id) }
            if updated.state == .ready {
                ArticleSendCoordinator.shared.articleBecameReady(updated)
            }
            // The save reached its terminal readable UI state — no further network.
            if let replayID {
                await recorder.terminate(replayID, state: .success, finalContent: resolvedContent)
            }
        case .paywalled(let title):
            store.markNeedsCaptcha(item.id, title: title)
            // NOT terminal: the user still solves the archive CAPTCHA in the web
            // reader, which owns its own (separate) replay. Mark this background
            // attempt failed so the diagnostic records that the silent path lost.
            if let replayID {
                await recorder.record(.resolveDecision(.paywalled), for: replayID)
                await recorder.terminate(replayID, state: .failed, finalContent: nil)
            }
        case .unreadable:
            // A hard-paywall host (WSJ/FT/…) or an already-archived URL can still be
            // read via its archive.today snapshot behind a user-solved CAPTCHA — park
            // it for the interactive archive reader instead of failing. Only a truly
            // unreachable URL on an ordinary site is a genuine failure.
            if ArticleFetcher.isHardPaywallHost(url) || ArticleFetcher.isArchiveTodayURL(url) {
                store.markNeedsCaptcha(item.id, title: ArticleFetcher.articleTitleGuess(from: url))
            } else {
                store.markFailed(item.id)
            }
            if let replayID {
                await recorder.record(.resolveDecision(.unreadable), for: replayID)
                await recorder.terminate(replayID, state: .failed, finalContent: nil)
            }
        }
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
    private func ingestProductTracker(
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

    /// Announces a just-created/merged price tracker from an INTERACTIVE save
    /// (paste / manual / app intent) so the foreground reading list can present
    /// the price-tracking screen (with a Cancel → save as article fallback).
    /// Background/extension/friend-share saves stay silent.
    private func postPriceTrackerSaved(
        itemID: UUID, source: CaptureSource, isMerge: Bool, highlightedURL: String?
    ) {
        switch source {
        case .paste, .manual, .appIntent:
            break
        case .shareSheet, .friendShare, .email:
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

    /// Downloads up to `maxImages` article images to the Articles directory and
    /// rewrites their blocks to point at the local files. Image blocks that
    /// fail to download are dropped so the reader never shows broken slots.
    private func downloadImages(for content: ArticleContent, itemID: UUID) async -> ArticleContent {
        let maxImages = 8
        let maxBytes = 5 * 1024 * 1024
        var downloaded = 0
        var blocks: [ArticleContent.Block] = []

        for var block in content.blocks {
            guard block.kind == .image else {
                blocks.append(block)
                continue
            }
            guard downloaded < maxImages,
                  let urlString = block.imageURLString,
                  let url = URL(string: urlString)
            else { continue }

            do {
                var request = URLRequest(url: url, timeoutInterval: 15)
                request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse,
                      (200..<300).contains(http.statusCode),
                      data.count > 1024, data.count <= maxBytes
                else { continue }

                let fileExtension = url.pathExtension.isEmpty ? "img" : url.pathExtension
                let fileName = "\(itemID.uuidString)-img\(downloaded).\(fileExtension)"
                try data.write(
                    to: store.articlesDirectory.appendingPathComponent(fileName),
                    options: .atomic)
                block.imageFileName = fileName
                blocks.append(block)
                downloaded += 1
            } catch {
                continue
            }
        }

        var updated = content
        updated.blocks = blocks
        return updated
    }

    /// Kicks off ingestion for everything not yet ready (app launch / foreground).
    func ingestAllPending() {
        // `.needsCaptcha` items can only advance when the user solves the archive
        // CAPTCHA, so a background re-fetch can't help them — retry only the states
        // that an automated pass can actually move forward.
        for item in store.items() where item.state == .pending || item.state == .failed {
            Task { await self.ingest(item) }
        }
    }

    /// What a save press did, so intents can wait on the right work.
    enum SavePressResult {
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
    func handleSavePress(urlString: String, source: CaptureSource = .manual) async -> SavePressResult {
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
    func saveAsArticle(urlString: String, source: CaptureSource = .manual) async {
        let item = store.item(forURLString: urlString) ?? store.add(urlString: urlString, source: source)
        await ingest(item, forceArticle: true)
    }

    /// Saves a NEW URL whose article content was already fetched (the pasteboard
    /// preview), persisting it directly so we skip a redundant network fetch.
    /// Runs the same new-save automation as a fresh save press.
    @discardableResult
    func saveNewWithContent(
        urlString: String, content: ArticleContent, source: CaptureSource = .manual
    ) async -> ReadingListItem {
        let item = store.add(urlString: urlString, source: source)
        fireAutoShares(urlString: urlString)
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
