//
//  ArticleIngestHandler.swift
//  LunaReaderUI
//

import LunaArchiveReader
import LunaDocuments
import LunaModels
import LunaStorage
import Foundation

/// Article-kind ingestion persistence, extracted from `ReadingListIngestor` so
/// only article-handling apps carry the reader/archive/document machinery. The
/// app shell installs this behind `IngestorKindHandlers.article` (via a thin
/// adapter in its `KindWiring` variant); `articleBecameReady` is injected
/// because the send pipeline (`ArticleSendCoordinator`, LunaSend) sits outside
/// LunaReaderUI's dependency tier.
public final class ArticleIngestHandler {

    /// Hook run when a saved item flips `.ready` — the app shell wires it to
    /// `ArticleSendCoordinator.articleBecameReady` so Kindle/ereader auto-sends
    /// keep firing exactly as before the extraction.
    private let articleBecameReady: (ReadingListItem) -> Void

    public init(articleBecameReady: @escaping (ReadingListItem) -> Void) {
        self.articleBecameReady = articleBecameReady
    }

    // MARK: - Articles

    /// Persists a readable article: downloads its images + cover art, saves the
    /// content, and flips ready.
    public func persistArticle(
        _ content: ArticleContent, html: String, for item: ReadingListItem,
        url: URL, store: ReadingListStore
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
            articleBecameReady(updated)
            // Background-preload this article's links so the inline link viewer opens
            // instantly. Non-blocking; no-op when the depth setting is 0.
            PreloadCoordinator.shared.preload(rootID: updated.id)
        }
        Task { [self] in
            await finishArticleArtifacts(
                initialContent, html: html, for: item, url: url, store: store)
        }
    }

    /// Finishes non-critical article artifacts after the row is already readable.
    /// This keeps ingestion latency tied to text extraction instead of remote media
    /// and WebKit archive capture.
    private func finishArticleArtifacts(
        _ content: ArticleContent, html: String, for item: ReadingListItem,
        url: URL, store: ReadingListStore
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
        await captureWebArchiveIfPossible(for: item, url: url, html: html, store: store)
    }

    // MARK: - Documents

    /// Document ingestion: parse the imported file (stored at
    /// `Articles/<id>-source.<type>`) into article content. Documents are
    /// Kindle-eligible, so the becameReady hook runs as for web articles.
    public func ingestDocument(_ item: ReadingListItem, store: ReadingListStore) async {
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
            articleBecameReady(updated)
        }
    }

    // MARK: - Web-archive backfill

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
    public func backfillMissingWebArchives(store: ReadingListStore) {
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
                await captureWebArchiveIfPossible(for: item, url: url, html: nil, store: store)
            }
        }
    }

    /// Captures and stores a cleaned `.webarchive`, preferring the resolver's exact
    /// unlocked HTML over a fresh live navigation that may reintroduce a paywall.
    private func captureWebArchiveIfPossible(
        for item: ReadingListItem, url: URL, html: String?, store: ReadingListStore
    ) async {
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

    // MARK: - Thumbnail backfill

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
    public func backfillMissingThumbnails(store: ReadingListStore) {
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
}
