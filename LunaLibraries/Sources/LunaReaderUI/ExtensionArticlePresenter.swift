//
//  ExtensionArticlePresenter.swift
//  LunaReaderUI
//

import LunaArchiveReader
import LunaAudioPlayback
import LunaHTMLClassification
import LunaIngest
import LunaModels
import LunaShareSurface
import LunaStorage
import UIKit

/// The article-kind side of the extension surfaces: the extension-context
/// article-save extras and the in-sheet/archive readers. Conforms to
/// `ShareArticlePresenting` (LunaShareSurface) directly, so
/// `ArticleKindComposition.install()` registers it as-is; `ExtensionReaderMode`
/// ↔ `ShareReaderViewController.Mode` share raw values by design, so the two
/// map onto each other with a rawValue round-trip.
@MainActor
public final class ExtensionArticlePresenter: ShareArticlePresenting {

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
        // Record the HTML that produced the native reader FIRST, synchronously. The
        // WebKit capture below needs seconds and the extension is killed as soon as
        // the sheet dismisses, so it usually loses that race — and the app's backfill
        // used to "repair" the loss with a LIVE capture, i.e. with the publisher's
        // paywalled page instead of the unlocked document the reader was built from.
        // With the source on disk the backfill finishes the job from the right one.
        if !html.isEmpty {
            store.saveReaderSourceHTML(html, for: item.id)
            let archiveStore = store
            let itemID = item.id
            Task {
                guard let archive = await WebArchiveCapturer.capture(html: html, baseURL: url),
                      let current = archiveStore.item(withID: itemID) else { return }
                archiveStore.saveWebArchive(archive, for: current)
                archiveStore.removeReaderSourceHTML(for: itemID)
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
    /// modal chrome.
    ///
    /// The reader is PREPARED before it is handed over — content persisted and
    /// image layout settled — so the host's own loading UI stays up until the
    /// finished article is ready to appear. That removes the intermediate screen
    /// the surface used to flash: a second spinner in a slightly different place,
    /// under a Done button that arrived before the article did.
    public func presentReader(url: URL, mode: ExtensionReaderMode, outcome: Outcome, host: ExtensionHost) {
        let readerMode = Self.readerMode(mode)
        let onModeChange: (ShareReaderViewController.Mode) -> Void = {
            ActionReaderMode.last = Self.extensionMode($0)
        }
        guard case let .article(content, _) = outcome else {
            // The driver only routes `.article` here; anything else keeps the
            // standalone reader's own outcome handling rather than a blank sheet.
            host.presentModally(ShareReaderViewController(
                url: url, mode: readerMode, outcome: outcome, onModeChange: onModeChange,
                onDone: { [weak host] in host?.confirmSavedThenComplete() }))
            return
        }
        Task { @MainActor [weak host] in
            guard let host else { return }
            host.presentModally(await ShareReaderViewController.preparedReader(
                url: url, mode: readerMode, content: content,
                onModeChange: onModeChange,
                onDone: { [weak host] in host?.confirmSavedThenComplete() }))
        }
    }

    /// Presents the archive-CAPTCHA reader for a paywalled article whose row
    /// (`itemID`) the driver already marked `.needsCaptcha`. On a successful
    /// extract, a surface with an in-sheet reader (`host.readerMode` non-nil)
    /// swaps in the native reader showing the captured content; the zero-UI
    /// share extension just confirms the save.
    public func presentArchive(url: URL, itemID: UUID, store: ReadingListStore, host: ExtensionHost) {
        let readerMode = host.readerMode.map(Self.readerMode)
        let archive = ArchiveWebReaderViewController(articleURL: url, itemID: itemID)
        archive.onClose = { [weak host] in host?.confirmSavedThenComplete() }
        archive.onExtracted = { [weak host] in
            // The driver (and this presenter) are intentionally short-lived.
            // Archive extraction finishes later, so `host` is captured weakly —
            // the same lifetime rule the rest of this presenter follows.
            if let readerMode,
               let fresh = store.item(withID: itemID),
               let content = store.content(for: fresh) {
                Task { @MainActor [weak host] in
                    guard let host else { return }
                    host.presentModally(await ShareReaderViewController.preparedReader(
                        url: url, mode: readerMode, content: content,
                        onModeChange: { ActionReaderMode.last = Self.extensionMode($0) },
                        onDone: { [weak host] in host?.confirmSavedThenComplete() }))
                }
            } else {
                host?.confirmSavedThenComplete()
            }
        }
        host.presentModally(archive)
    }

    /// `ExtensionReaderMode` (surface) ↔ `ShareReaderViewController.Mode`
    /// (article kind) share raw values by design.
    private static func readerMode(_ mode: ExtensionReaderMode) -> ShareReaderViewController.Mode {
        ShareReaderViewController.Mode(rawValue: mode.rawValue) ?? .reader
    }

    private static func extensionMode(_ mode: ShareReaderViewController.Mode) -> ExtensionReaderMode {
        ExtensionReaderMode(rawValue: mode.rawValue) ?? .reader
    }
}
