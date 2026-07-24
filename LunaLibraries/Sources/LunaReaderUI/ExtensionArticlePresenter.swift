//
//  ExtensionArticlePresenter.swift
//  LunaReaderUI
//

import LunaArchiveReader
import LunaAudioPlayback
import LunaHTMLClassification
import LunaIngest
import LunaModels
import LunaStorage
import UIKit

/// The article-kind side of the extension surfaces: the extension-context
/// article-save extras and the in-sheet/archive readers. Protocol-free — each
/// extension target's composition root (`ShareEntry+*` / `ActionEntry+*`)
/// wraps it in a small adapter conforming to `ShareArticlePresenting`
/// (LunaShareSurface), the same shape as the `IngestKindProcessors` /
/// `IngestorKindHandlers` wiring. Host side effects arrive as closures so this
/// module never sees the surface's `ExtensionHost`.
@MainActor
public final class ExtensionArticlePresenter {

    public init() {}

    /// The extension-context extras after an article save (the store write
    /// itself stays in `ShareSurfaceDriver`); every step is a no-op on empty
    /// `html`, exactly as when this lived in the driver.
    public func persistArticleExtras(
        item: ReadingListItem, content: ArticleContent, html: String, url: URL,
        store: ReadingListStore
    ) {
        // Phase 6, product requirement B: write a heuristics-only audio
        // script to the cache right away — cheap/synchronous, off the ingest
        // critical path below (thumbnail fetch) — so the article is
        // audio-ready before the main app's `AudioScriptPipeline` sweep gets
        // to it. Reuses the exact same store/heuristics the main pipeline
        // does; a no-op if a script is already cached.
        ExtensionAudioScriptWriter.writeHeuristicScriptIfNeeded(
            item: item, content: content, articlesDirectory: store.articlesDirectory)
        // Best-effort while the extension remains alive: archive the SAME unlocked
        // HTML that produced the native reader, with the shared ad/paywall cleanup.
        // If the process ends first, the main app's cleaned live backfill repairs it.
        if !html.isEmpty {
            let archiveStore = store
            let itemID = item.id
            Task {
                guard let archive = await WebArchiveCapturer.capture(html: html, baseURL: url),
                      let current = archiveStore.item(withID: itemID) else { return }
                archiveStore.saveWebArchive(archive, for: current)
            }
        }
        // Give the row the SAME cover thumbnail an in-app save produces. Best-effort
        // from the page HTML the pipeline already fetched (Safari's text-only action
        // snapshot has no og:image, so it simply yields no cover here). The extension
        // is short-lived, so if this doesn't finish the app backfills it on next launch
        // (ReadingListIngestor.backfillMissingThumbnails) — this just avoids the wait
        // in the common case. Skipped for the text-only snapshot, which has no <meta>.
        guard !html.isEmpty else { return }
        let itemID = item.id
        Task {
            guard store.item(withID: itemID)?.thumbnailFileName == nil,
                  let data = await ArticleCoverThumbnail.coverImageData(html: html, baseURL: url)
            else { return }
            store.setThumbnail(data, for: itemID)
        }
    }

    /// Presents the in-sheet article reader (action extension) in the host's
    /// modal chrome; `complete` is the reader's Done.
    public func presentReader(
        url: URL, mode: ShareReaderViewController.Mode, outcome: Outcome,
        onModeChange: ((ShareReaderViewController.Mode) -> Void)?,
        presentModally: (UIViewController) -> Void,
        complete: @escaping () -> Void
    ) {
        presentModally(ShareReaderViewController(
            url: url, mode: mode, outcome: outcome, onModeChange: onModeChange,
            onDone: complete))
    }

    /// Presents the archive-CAPTCHA reader for a paywalled article whose row
    /// (`itemID`) the driver already marked `.needsCaptcha`. On a successful
    /// extract, a surface with an in-sheet reader (`readerMode` non-nil) swaps
    /// in the native reader showing the captured content; the zero-UI share
    /// extension just confirms the save.
    public func presentArchive(
        url: URL, itemID: UUID, readerMode: ShareReaderViewController.Mode?,
        store: ReadingListStore,
        onModeChange: ((ShareReaderViewController.Mode) -> Void)?,
        presentModally: @escaping (UIViewController) -> Void,
        complete: @escaping () -> Void
    ) {
        let archive = ArchiveWebReaderViewController(articleURL: url, itemID: itemID)
        archive.onClose = { complete() }
        archive.onExtracted = {
            // The driver (and this presenter) are intentionally short-lived.
            // Archive extraction finishes later, so everything the swap needs —
            // the host's present/complete closures, the store — is captured
            // here rather than reached through a weak driver.
            if let readerMode,
               let fresh = store.item(withID: itemID),
               let content = store.content(for: fresh) {
                let reader = ShareReaderViewController(
                    url: url, mode: readerMode, outcome: .article(content, html: ""),
                    onModeChange: onModeChange, onDone: complete)
                presentModally(reader)
            } else {
                complete()
            }
        }
        presentModally(archive)
    }
}
