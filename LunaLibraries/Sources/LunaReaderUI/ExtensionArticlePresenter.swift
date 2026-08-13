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
        let legs = ExtensionReaderLegs(host: host)
        guard case let .article(content, _) = outcome else {
            // The driver only routes `.article` here; anything else keeps the
            // standalone reader's own outcome handling rather than a blank sheet.
            host.presentModally(ShareReaderViewController(
                url: url, mode: readerMode, outcome: outcome,
                modePreferenceDelegate: legs, completionDelegate: legs))
            return
        }
        Task { @MainActor [weak host] in
            guard let host else { return }
            host.presentModally(await ShareReaderViewController.preparedReader(
                url: url, mode: readerMode, content: content,
                modePreferenceDelegate: legs, completionDelegate: legs))
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
        archive.delegate = ExtensionUnlockLegs(
            host: host, url: url, itemID: itemID, store: store, readerMode: readerMode)
        host.presentModally(archive)
    }

    /// `ExtensionReaderMode` (surface) ↔ `ShareReaderViewController.Mode`
    /// (article kind) share raw values by design.
    private static func readerMode(_ mode: ExtensionReaderMode) -> ShareReaderViewController.Mode {
        ShareReaderViewController.Mode(rawValue: mode.rawValue) ?? .reader
    }

    fileprivate static func extensionMode(_ mode: ShareReaderViewController.Mode) -> ExtensionReaderMode {
        ExtensionReaderMode(rawValue: mode.rawValue) ?? .reader
    }
}

/// The in-sheet reader's two host legs, kept together for the life of the sheet.
///
/// A small coordinator rather than the presenter itself: the driver AND this presenter
/// are intentionally short-lived, while the reader stays up until the user leaves it.
/// The reader (and its Done bar item) retain this; this holds the host weakly, so
/// nothing cycles.
///
/// Two protocols on one object because the two legs share one owner, not because they
/// are one event: exiting the extension and remembering a mode are unrelated, and only
/// the exit is mandatory.
@MainActor
private final class ExtensionReaderLegs: ShareReaderCompletionDelegate,
    ReaderModePreferenceDelegate {
    private weak var host: (any ExtensionHost)?

    init(host: any ExtensionHost) {
        self.host = host
    }

    func shareReaderDidFinish() {
        host?.confirmSavedThenComplete()
    }

    /// The action extension keeps its own last-used mode. The reader speaks in
    /// `ReadingListItem.ReaderMode`; the surface stores `ExtensionReaderMode`, and
    /// `ShareReaderViewController.Mode` is the shared vocabulary between them.
    func reader(_ reader: UIViewController, didSelectMode mode: ReadingListItem.ReaderMode) {
        ActionReaderMode.last = ExtensionArticlePresenter.extensionMode(
            ShareReaderViewController.Mode(readerMode: mode))
    }
}

/// The extension archive unlock's two legs, kept together for the life of the card.
///
/// A small coordinator rather than the presenter itself: the driver AND this
/// presenter are intentionally short-lived, while archive extraction finishes later.
/// The reader retains this; this holds the host weakly — the same lifetime rule the
/// rest of the presenter follows, and the same shape the two closures it replaces had.
///
/// It declares no Safari escape and takes the protocol's `false`: an extension has no
/// `UIApplication` to leave Luna with, so both escapes stay hidden.
@MainActor
private final class ExtensionUnlockLegs: ArchiveUnlockDelegate {
    private weak var host: (any ExtensionHost)?
    private let url: URL
    private let itemID: UUID
    private let store: ReadingListStore
    /// The in-sheet reader to swap in once the article lands, or nil for the zero-UI
    /// share extension, which just confirms the save.
    private let readerMode: ShareReaderViewController.Mode?

    init(
        host: any ExtensionHost, url: URL, itemID: UUID, store: ReadingListStore,
        readerMode: ShareReaderViewController.Mode?
    ) {
        self.host = host
        self.url = url
        self.itemID = itemID
        self.store = store
        self.readerMode = readerMode
    }

    func archiveReaderDidUnlockArticle(_ reader: ArchiveWebReaderViewController) {
        guard let readerMode,
              let fresh = store.item(withID: itemID),
              let content = store.content(for: fresh) else {
            host?.confirmSavedThenComplete()
            return
        }
        let url = url
        Task { @MainActor [weak host] in
            guard let host else { return }
            let legs = ExtensionReaderLegs(host: host)
            host.presentModally(await ShareReaderViewController.preparedReader(
                url: url, mode: readerMode, content: content,
                modePreferenceDelegate: legs, completionDelegate: legs))
        }
    }

    func archiveReaderDidClose(_ reader: ArchiveWebReaderViewController) {
        host?.confirmSavedThenComplete()
    }
}
