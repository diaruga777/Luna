//
//  ArticleIngestHandler.swift
//  LunaReaderUI
//

import LunaArchiveReader
import LunaDocuments
import LunaHTMLClassification
import LunaModels
import LunaPaywallBypass
import LunaStorage
import Foundation

/// Article-kind ingestion persistence, extracted from `SavesIngestor` so
/// only article-handling apps carry the reader/archive/document machinery. The
/// app shell installs this behind `IngestorKindHandlers.article` (via a thin
/// adapter in its `KindWiring` variant).
///
/// A persisted article reports itself through `SaveReadiness.observer`, the one
/// readiness path every kind uses: the send pipeline
/// (`ArticleSendCoordinator`, LunaSend) sits outside LunaReaderUI's dependency
/// tier, so the app shell installs the witness there.
public final class ArticleIngestHandler {

    private let subscriptionRepairResolver: (URL) async -> ArticleResolution

    public init(
        subscriptionRepairResolver: @escaping (URL) async -> ArticleResolution = {
            await ArticleResolver.resolve(url: $0)
        }
    ) {
        self.subscriptionRepairResolver = subscriptionRepairResolver
    }

    // MARK: - Articles

    /// Persists a readable article: downloads its images + cover art, saves the
    /// content, and flips ready.
    public func persistArticle(
        _ content: ArticleContent, html: String, for item: SavedItem,
        url: URL, store: SavesStore
    ) async {
        // A row that is ALREADY ready is having its content replaced — a
        // recovery file for a save that captured the wrong article
        // (`claudedocs/llm-handoff.md`). Its artwork belongs to the text being
        // replaced, so the new cover takes it over.
        let replacesExistingContent = item.state == .ready
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
            SaveReadiness.observer?.saveBecameReady(updated)
            // Background-preload this article's links so the inline link viewer opens
            // instantly. Non-blocking; no-op when the depth setting is 0.
            PreloadCoordinator.shared.preload(rootID: updated.id)
        }
        Task { [self] in
            await finishArticleArtifacts(
                initialContent, html: html, for: item, url: url, store: store,
                replacesExistingContent: replacesExistingContent)
        }
    }

    /// Finishes non-critical article artifacts after the row is already readable.
    /// This keeps ingestion latency tied to text extraction instead of remote media
    /// and WebKit archive capture.
    private func finishArticleArtifacts(
        _ content: ArticleContent, html: String, for item: SavedItem,
        url: URL, store: SavesStore, replacesExistingContent: Bool = false
    ) async {
        async let downloadedContent = ArticleImageDownloader.download(
            content, itemID: item.id, store: store, refererURL: url)
        async let coverData = ArticleCoverThumbnail.coverImageData(html: html, baseURL: url)

        if let coverData = await coverData,
           replacesExistingContent || store.item(withID: item.id)?.thumbnailFileName == nil {
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
    public func ingestDocument(_ item: SavedItem, store: SavesStore) async {
        guard let type = item.sanitizedDocumentType else {
            store.markFailed(item.id)
            return
        }
        let sourceURL = store.articlesDirectory
            .appendingPathComponent("\(item.id.uuidString)-source.\(type)")
        guard let content = DocumentParser.parse(
            fileURL: sourceURL, type: type, title: item.title ?? L10n.string("Common_document"),
            imagesDirectory: store.articlesDirectory)
        else {
            store.markFailed(item.id)
            return
        }
        let updated = store.saveContent(content, for: item)
        if updated.state == .ready {
            SaveReadiness.observer?.saveBecameReady(updated)
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
    @MainActor private var subscriptionRepairAttempted: Set<UUID> = []

    /// `.webarchive` capture was added after many items were saved, and several save
    /// surfaces (extensions, paste, friend-share) don't capture inline. This repairs
    /// every ready web page that lacks an archive — one WebKit capture at a time so we
    /// never run a fleet of web views — which is also how those surfaces get covered.
    ///
    /// It captures from the item's saved reader-source HTML when one is on disk (the
    /// share extension leaves it exactly so this pass can finish its work from the
    /// right document); only a save with no recorded source falls back to a live
    /// navigation.
    public func backfillMissingWebArchives(store: SavesStore) {
        Task { @MainActor in
            guard !isBackfillingArchives else { return }
            isBackfillingArchives = true
            defer { isBackfillingArchives = false }

            await repairBostonGlobeSubscriptionSaves(store: store)

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

    /// Older Globe saves may already be `.ready` with a long subscription
    /// pitch. A normal pending-save sweep intentionally skips ready rows, so
    /// replace only unmistakable offers when the app next runs its backfills.
    /// Failed attempts leave the old row untouched; one attempt per session
    /// avoids repeated network work on every foreground transition.
    @MainActor
    func repairBostonGlobeSubscriptionSaves(store: SavesStore) async {
        guard !URLBehaviorPolicy.pluginsOnly else { return }
        let candidates = store.items().filter { item in
            guard item.state == .ready,
                  !subscriptionRepairAttempted.contains(item.id),
                  let url = item.url,
                  let content = store.content(for: item) else { return false }
            return Self.isBostonGlobeSubscriptionOffer(content, url: url)
        }
        for item in candidates.prefix(4) {
            guard let url = item.url else { continue }
            subscriptionRepairAttempted.insert(item.id)
            let resolution = await subscriptionRepairResolver(url)
            guard case let .readable(content, html) = resolution,
                  !Self.isBostonGlobeSubscriptionOffer(content, url: url),
                  let current = store.item(withID: item.id), current.state == .ready
            else { continue }
            await persistArticle(content, html: html, for: current, url: url, store: store)
        }
    }

    static func isBostonGlobeSubscriptionOffer(_ content: ArticleContent, url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host == "bostonglobe.com" || host.hasSuffix(".bostonglobe.com")
        else { return false }
        let opening = content.wholeText.prefix(2_000).lowercased()
        if PaywallDetector.gateMarkers.contains(where: opening.contains) { return true }
        let offerAction = ["subscribe now", "become a subscriber", "start your subscription",
                           "choose your plan", "subscribe to read"].contains(where: opening.contains)
        let offerProduct = ["digital access", "unlimited access", "subscriber benefits",
                            "subscription offer", "subscription plan"].contains(where: opening.contains)
        return offerAction && offerProduct
    }

    /// Captures and stores a cleaned `.webarchive` from the HTML that produced the
    /// reader — the ONE document "Original" is supposed to show.
    ///
    /// A live navigation is only for a save with no recorded source HTML at all
    /// (legacy rows, and the Safari text-only action snapshot, which carries none).
    /// It is NOT a fallback for a failed capture: whenever the reader content came
    /// from a bypass, the live page is a DIFFERENT document — the Paris Review serves
    /// a 12k-character teaser under a subscribe card where the reader holds the whole
    /// 49k interview — so archiving it produces a wrong, un-dismissible "original".
    /// With no archive, the reader falls back to a styled snapshot of the saved
    /// content, which IS the version the user read.
    private func captureWebArchiveIfPossible(
        for item: SavedItem, url: URL, html: String?, store: SavesStore
    ) async {
        guard url.scheme?.hasPrefix("http") ?? false else { return }   // never for lunamail://, lunadoc://
        // Record the capture input before the (up-to-20s) capture, so a process that
        // dies mid-flight — the share extension always does — leaves the backfill
        // something better than the live page to work from.
        if let html, !html.isEmpty {
            store.saveReaderSourceHTML(html, for: item.id)
        }
        let sourceHTML = html?.isEmpty == false ? html : store.readerSourceHTML(for: item.id)
        let archive: Data?
        if let sourceHTML {
            archive = await WebArchiveCapturer.capture(html: sourceHTML, baseURL: url)
        } else {
            guard !URLBehaviorPolicy.pluginsOnly else { return }
            archive = await WebArchiveCapturer.capture(url: url)
        }
        guard let archive, let current = store.item(withID: item.id) else { return }
        store.saveWebArchive(archive, for: current)
        store.removeReaderSourceHTML(for: item.id)
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
    public func backfillMissingThumbnails(store: SavesStore) {
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
