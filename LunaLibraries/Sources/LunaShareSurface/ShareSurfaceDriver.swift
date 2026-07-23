//
//  ShareSurfaceDriver.swift
//  ShareKit
//

import LunaPriceUI
import LunaReaderUI
import LunaArchiveReader
import LunaAudioPlayback
import LunaMediaDownload
import LunaStorage
import LunaIngest
import LunaModels
import LunaHTMLClassification
import LunaURLClassification
import UIKit

/// The HOST-AGNOSTIC ingest+present flow for the share/action extension surfaces.
///
/// It runs the ONE shared `IngestPipeline` for an appended URL and presents the
/// resulting `Outcome` through an injected `ExtensionHost`, so the WHOLE flow is
/// testable with a fake host (the real `NSExtensionContext` harness is not — a
/// simulator can't drive the share sheet and `completeRequest`/`inputItems` have no
/// test seam). The real `ShareViewController` is a thin adapter that conforms to
/// `ExtensionHost` and owns only attachment loading + the live UIKit chrome; this
/// driver owns the decision/persistence/presentation that must stay IDENTICAL to
/// every other surface.
///
/// Differences between the share extension and the action extension are pure DATA
/// (`host.isActionExtension` / `host.readerMode`), never divergent processing logic
/// — both call the same pipeline and exhaustive `Outcome` switch here. Every case
/// persists the classified metadata to the shared store (so an extension save is
/// shaped identically to a main-app save. Presentation policy is narrow: the action extension shows its
/// reader/saved UI, while the share extension only presents media, price, and
/// archive-bypass UI.
@MainActor
public final class ShareSurfaceDriver {

    private weak var host: ExtensionHost?
    private let store: ReadingListStore
    /// Injectable so tests can drive the pipeline with a mock fetcher / fixtures and
    /// a nil render tier (extension-safe). Production uses the live defaults.
    private let process: (IngestInput) async -> IngestResult
    /// The per-app content gate over the classified outcome (`SurfaceSupport`):
    /// a single-content app's extension drops foreign kinds. Injectable so
    /// tests can pin the running app without touching `Bundle.main`.
    private let surfaceDecision: (Outcome) -> SurfaceSupport.Decision
    /// The app the extension is running in, for the error copy + deep links.
    private let currentApp: LunaApp

    public init(
        host: ExtensionHost,
        store: ReadingListStore = .shared,
        process: @escaping (IngestInput) async -> IngestResult = {
            await IngestPipeline.processResolved($0)
        },
        surfaceDecision: @escaping (Outcome) -> SurfaceSupport.Decision = {
            SurfaceSupport.evaluateForCurrentProcess(owner: $0.owningApp)
        },
        currentApp: LunaApp = .current
    ) {
        self.host = host
        self.store = store
        self.process = process
        self.surfaceDecision = surfaceDecision
        self.currentApp = currentApp
    }

    /// Runs the shared pipeline for the just-appended `originalURL`, repoints the saved
    /// item to the pipeline's resolved URL, then presents + persists the `Outcome` via
    /// this surface's host.
    public func ingestAndPresent(originalURL: URL, prefetchedHTML: String? = nil) async {
        // Keep the identity of THIS extension request's placeholder. Resolution
        // can discover that its canonical URL is already saved and delete the
        // placeholder; a later blocked decision must never then delete that
        // pre-existing canonical item merely because it has the resolved URL.
        let pendingItemID = store.item(forURLString: originalURL.absoluteString)?.id
        let result = await process(IngestInput(
            url: originalURL, source: .shareSheet, prefetchedHTML: prefetchedHTML))

        let url = result.url
        if url != originalURL, let item = store.item(forURLString: originalURL.absoluteString) {
            // The item was saved keyed on the pre-resolve (wrapper/shortener) URL, but
            // the pipeline resolved it to the publisher URL. If that publisher URL is
            // ALREADY saved (e.g. shared once directly, once via apple.news), repointing
            // would create two items at the same URL — instead drop the wrapper item and
            // keep the existing one, so the same article never duplicates.
            if let existing = store.item(forURLString: url.absoluteString), existing.id != item.id {
                store.delete(item)
            } else {
                _ = store.updateURL(url.absoluteString, for: item.id)
            }
        }
        present(result.outcome, url: url, blockedItemID: pendingItemID)
    }

    /// The EXHAUSTIVE per-surface presenter over the unified `Outcome` (no `default`,
    /// compiler-checked). Public so the fixture can drive it directly with any Outcome.
    ///
    /// The per-app content gate runs FIRST, before any persist: a foreign-kind
    /// outcome deletes the pending row `ShareViewController` appended before
    /// classification (with its copied document file, via `store.delete`'s
    /// `removeFiles`) so NOTHING remains in the store, and the generic
    /// unsupported-kind error is presented instead of any save UI (never a
    /// "Saved" checkmark). A supported outcome (or `.failed`'s nil owner)
    /// persists and presents exactly as before.
    public func present(_ outcome: Outcome, url: URL, blockedItemID: UUID? = nil) {
        guard let host else { return }

        if case let .unsupported(owner) = surfaceDecision(outcome) {
            discardUnsupportedSave(url: url, itemID: blockedItemID)
            presentUnsupportedError(owner: owner)
            return
        }

        switch outcome {
        case let .article(content, html):
            persistArticle(content, html: html, url: url)
            if let mode = host.readerMode {
                presentReader(url: url, mode: mode, outcome: outcome)
            } else {
                host.completeSilently()
            }

        case let .product(product, _):
            // Persist the tracker, then present the SAME price-tracking editor the
            // main app shows (the extension host wraps it in Done chrome).
            presentPriceEditor(product: product, url: url)

        case let .video(platform, itemID):
            persistPlatform(platform, itemID: itemID, url: url)
            presentNonTextual(url: url)

        case let .social(platform, itemID):
            persistPlatform(platform, itemID: itemID, url: url)
            presentNonTextual(url: url)

        case .document:
            if host.readerMode != nil {
                host.confirmSavedThenComplete()
            } else {
                host.completeSilently()
            }

        case let .needsArchive(title):
            presentArchive(url: url, title: title)

        case .failed:
            // NEVER a misleading "Saved". Mark the row failed so the main app's list
            // shows it, then offer the Apple-Intelligence rescue hand-off: the action
            // extension (which has UI) presents the rescue card; the zero-UI share
            // extension completes quietly (the main app's background sweep still
            // rescues it if auto-rescue is on).
            store.item(forURLString: url.absoluteString).map { store.markFailed($0.id) }
            if host.readerMode != nil {
                presentRescueFailure(url: url)
            } else {
                host.completeSilently()
            }
        }
    }

    /// The action-extension failure card: pick a hint, write a pending-rescue
    /// record, best-effort open the containing app. The extension links NO rescue
    /// engine — only the pending-record store + the deep link.
    private func presentRescueFailure(url: URL) {
        guard let host else { return }
        let app = currentApp
        let card = RescueFailureViewController(
            defaultHint: Self.defaultHint(for: app),
            rescueURL: LunaDeepLink.rescueLink(scheme: app.deepLinkScheme),
            openApp: { [weak host] in host?.openURL($0) },
            onFinish: { chosen in
                PendingRescueRequestStore.shared.append(PendingRescueRequest(
                    urlString: url.absoluteString, hint: chosen, dateWritten: Date(),
                    sourceSurface: app.storageIdentifier))
            },
            onDone: { [weak host] in host?.completeSilently() })
        host.presentModally(card)
    }

    /// The natural rescue hint for an app (matches the app-shell mapping).
    public static func defaultHint(for app: LunaApp) -> RescueHint {
        switch app {
        case .luna, .reader: return .article
        case .downloader: return .media
        case .priceTracker: return .product
        }
    }

    // MARK: - Surface gate (per-app content kinds)

    /// Deletes the pending placeholder row appended before classification, so a
    /// dropped foreign-kind save leaves NOTHING behind. `store.delete` also
    /// removes every on-disk artifact the row owns — including an imported
    /// document's copied `Articles/<id>-source.<ext>` file.
    private func discardUnsupportedSave(url: URL, itemID: UUID?) {
        if let itemID {
            // If wrapper dedup already removed this request's placeholder, the
            // correct blocked cleanup is a no-op. Do not fall back to URL lookup:
            // that URL belongs to the older, legitimate save.
            guard let item = store.item(withID: itemID) else { return }
            store.delete(item)
            return
        }
        guard let item = store.item(forURLString: url.absoluteString) else { return }
        store.delete(item)
    }

    /// Presents the generic unsupported-kind error in the host's modal chrome.
    /// Done completes silently — nothing was saved, never a "Saved" checkmark.
    private func presentUnsupportedError(owner: LunaApp) {
        guard let host else { return }
        let error = UnsupportedSaveViewController(owner: owner, currentApp: currentApp)
        error.onDone = { [weak host] in host?.completeSilently() }
        host.presentModally(error)
    }

    // MARK: - Store writes (shared shape with the main app's IngestorOutcomePresenter)

    private func persistArticle(_ content: ArticleContent, html: String, url: URL) {
        guard let saved = store.item(forURLString: url.absoluteString) else { return }
        let savedWithContent = store.saveContent(content, for: saved)
        // Phase 6, product requirement B: write a heuristics-only audio
        // script to the cache right away — cheap/synchronous, off the ingest
        // critical path below (thumbnail fetch) — so the article is
        // audio-ready before the main app's `AudioScriptPipeline` sweep gets
        // to it. Reuses the exact same store/heuristics the main pipeline
        // does; a no-op if a script is already cached.
        ExtensionAudioScriptWriter.writeHeuristicScriptIfNeeded(
            item: savedWithContent, content: content, articlesDirectory: store.articlesDirectory)
        // Best-effort while the extension remains alive: archive the SAME unlocked
        // HTML that produced the native reader, with the shared ad/paywall cleanup.
        // If the process ends first, the main app's cleaned live backfill repairs it.
        if !html.isEmpty {
            let archiveStore = store
            let itemID = saved.id
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
        let store = store
        let itemID = saved.id
        Task {
            guard store.item(withID: itemID)?.thumbnailFileName == nil,
                  let data = await ArticleCoverThumbnail.coverImageData(html: html, baseURL: url)
            else { return }
            store.setThumbnail(data, for: itemID)
        }
    }

    /// Persists a recognized video/social item's classification.
    private func persistPlatform(
        _ platform: ContentPlatform, itemID: String?, url: URL
    ) {
        guard let saved = store.item(forURLString: url.absoluteString) else { return }
        _ = store.savePlatformMetadata(
            platform: platform, platformItemID: itemID, title: nil, creator: nil,
            thumbnailFileName: nil, for: saved.id)
    }

    private func persistTracker(_ product: ProductInfo, url: URL) -> UUID? {
        Self.persistTracker(product, url: url, store: store)
    }

    /// Builds and saves the `PriceTracker` for a classified product page. Shared
    /// with `ShareReaderViewController`, which reaches this same store write when
    /// it's presenting a precomputed `Outcome` standalone rather than through
    /// `present(_:url:blockedItemID:)`.
    @discardableResult
    static func persistTracker(_ product: ProductInfo, url: URL, store: ReadingListStore) -> UUID? {
        guard let saved = store.item(forURLString: url.absoluteString) else { return nil }
        let tracker = PriceTracker(
            productName: product.name, stores: product.trackerStores(fallbackURL: url),
            brand: product.brand, productID: product.productID)
        store.savePriceTracker(tracker, for: saved.id)
        return saved.id
    }

    // MARK: - Presentation

    private func presentReader(
        url: URL, mode: ShareReaderViewController.Mode, outcome: Outcome
    ) {
        guard let host else { return }
        let reader = ShareReaderViewController(url: url, mode: mode, outcome: outcome) { [weak host] in
            host?.confirmSavedThenComplete()
        }
        host.presentModally(reader)
    }

    /// Routes a non-textual outcome. Downloadable social media always opens the
    /// saved-content screen on BOTH extension surfaces so the user can explicitly
    /// choose the media download. Non-downloadable items retain the share
    /// extension's silent-save behavior.
    private func presentNonTextual(url: URL) {
        guard let host else { return }
        if host.readerMode != nil || MediaDownloadablePlatform.supports(url.absoluteString) {
            let saved = SavedNonTextualViewController(
                articleURLString: url.absoluteString) { [weak host] in
                host?.confirmSavedThenComplete()
            }
            host.presentModally(saved)
        } else {
            host.autoDownloadThenComplete(urlString: url.absoluteString)
        }
    }

    /// Presents the SAME price-tracking editor as the main app, in the extension's host
    /// (Done chrome). The tracker is persisted first so the editor has an item. "Read
    /// instead" re-appends the URL to the shared store (extension-safe: the main app
    /// ingests it on next launch); the editor handles the tracker delete.
    private func presentPriceEditor(product: ProductInfo, url: URL) {
        guard let host else { return }
        guard let itemID = persistTracker(product, url: url) else {
            host.confirmSavedThenComplete()
            return
        }
        let editor = PriceTrackingViewController(
            mode: .creation(itemID: itemID, host: .extension),
            onReadInstead: { urlString in SharedReadingListAppender.append(urlString: urlString) })
        editor.onDone = { [weak host] in host?.confirmSavedThenComplete() }
        host.presentModally(editor)
    }

    /// A paywalled article: EVERY surface opens the same `ArchiveWebReaderViewController`
    /// (the archive-CAPTCHA reader, URL pre-filled), identically to the main app, so the
    /// presentation intent matches across surfaces. On a successful extract the action
    /// extension swaps in the in-sheet native reader showing the captured content; the
    /// zero-UI share extension confirms the save.
    private func presentArchive(url: URL, title: String) {
        guard let host else { return }
        guard let saved = store.item(forURLString: url.absoluteString) else {
            host.confirmSavedThenComplete()
            return
        }
        store.markNeedsCaptcha(saved.id, title: title)
        let archiveStore = store
        let archive = ArchiveWebReaderViewController(articleURL: url, itemID: saved.id)
        archive.onClose = { [weak host] in host?.confirmSavedThenComplete() }
        let mode = host.readerMode
        archive.onExtracted = { [weak host] in
            guard let host else { return }
            if let mode,
               let fresh = archiveStore.item(withID: saved.id),
               let content = archiveStore.content(for: fresh) {
                // `ShareSurfaceDriver` is intentionally short-lived. Archive
                // extraction finishes later, so never depend on a weak driver here:
                // create the action-extension reader directly in the host's existing
                // navigation context instead of falling through to "Saved".
                let reader = ShareReaderViewController(
                    url: url, mode: mode, outcome: .article(content, html: "")) {
                    host.confirmSavedThenComplete()
                }
                host.presentModally(reader)
            } else {
                host.confirmSavedThenComplete()
            }
        }
        host.presentModally(archive)
    }
}
