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

    /// IDs currently being ingested, to avoid duplicate concurrent work.
    private var inFlight = Set<UUID>()
    private let lock = NSLock()

    /// Fetches and extracts content for one item. Safe to call repeatedly.
    func ingest(_ item: ReadingListItem) async {
        guard item.state != .ready, let url = item.url else { return }

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

        if item.isDocument {
            await ingestDocument(item)
            return
        }

        if let videoID = YouTubeURL.videoID(from: item.urlString) {
            await ingestYouTubeVideo(item, videoID: videoID)
            return
        }

        // A recognized platform URL (X, Bluesky, …) is accepted as a no-content
        // item — NEVER run through the article extractor (which would fail and
        // mark it "Couldn't Load").
        if let match = PlatformRegistry.shared.detect(item.urlString) {
            await ingestPlatformItem(item, match: match)
            return
        }

        do {
            let html = try await fetcher.fetchHTML(from: url)
            var content = try extractor.extract(html: html, baseURL: url)
            content = await downloadImages(for: content, itemID: item.id)
            // Best-effort cover/banner art for the list row (kept before the
            // ready flip so the row's spinner covers the whole fetch).
            let coverData = await fetchCoverImageData(html: html, baseURL: url)
            let updated = store.saveContent(content, for: item)
            if let coverData { store.setThumbnail(coverData, for: item.id) }
            if updated.state == .ready {
                ArticleSendCoordinator.shared.articleBecameReady(updated)
            }
        } catch {
            store.markFailed(item.id)
        }
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
        guard let type = item.documentType else {
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
        for item in store.items() where item.state != .ready {
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
