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
import LunaInterop
import LunaInteropUI
import LunaHTMLClassification
import LunaURLClassification
import LunaModels
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
    /// The cross-app-interop gate over the classified outcome
    /// (`claudedocs/interop-purchase.md`). Extension saves are always
    /// `.shareSheet` — a gated source — so the decision only depends on the
    /// outcome's owner + payment/install state. Injectable so tests can pin
    /// surface/unlock/install without touching the App Group.
    private let interopDecision: (Outcome) -> InteropGate.Decision
    /// The surface the extension is running in, for the prompt's "unlock in
    /// <this app>" copy + deep link.
    private let currentSurface: InteropSurface

    public init(
        host: ExtensionHost,
        store: ReadingListStore = .shared,
        process: @escaping (IngestInput) async -> IngestResult = {
            await IngestPipeline.processResolved($0)
        },
        interopDecision: @escaping (Outcome) -> InteropGate.Decision = {
            InteropGate.evaluateForCurrentProcess(owner: $0.interopOwner)
        },
        currentSurface: InteropSurface = .current
    ) {
        self.host = host
        self.store = store
        self.process = process
        self.interopDecision = interopDecision
        self.currentSurface = currentSurface
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
    /// The cross-app-interop gate runs FIRST, before any persist
    /// (`claudedocs/interop-purchase.md`):
    /// - `.blocked` (unpaid cross-surface): the pending row `ShareViewController`
    ///   appended before classification is deleted (with its copied document
    ///   file, via `store.delete`'s `removeFiles`) so NOTHING remains in the
    ///   store, and the interop prompt (install step if the owner is missing +
    ///   the pay step) is presented instead of any save UI.
    /// - `.allowedNeedsInstall` (paid, owner uninstalled): the save proceeds
    ///   byte-identically to today, and the informational install prompt
    ///   REPLACES only the silent terminals (the zero-UI share extension's
    ///   `completeSilently`/checkmark endings) — flows that already present
    ///   interactive UI (reader, price editor, saved-media screen, archive
    ///   reader) are left alone rather than stacking a second sheet.
    /// - `.allowed` (same-surface, or `.failed`'s nil owner): exactly today.
    public func present(_ outcome: Outcome, url: URL, blockedItemID: UUID? = nil) {
        guard let host else { return }

        let decision = interopDecision(outcome)
        if case let .blocked(owner, ownerInstalled) = decision {
            discardBlockedSave(url: url, itemID: blockedItemID)
            presentInteropPrompt(
                kind: .blocked(owner: owner, ownerInstalled: ownerInstalled),
                terminal: { [weak host] in host?.completeSilently() })
            return
        }
        let installNote: InteropPromptKind? = {
            if case let .allowedNeedsInstall(owner) = decision {
                return .needsInstall(owner: owner)
            }
            return nil
        }()

        switch outcome {
        case let .article(content, html):
            persistArticle(content, html: html, url: url)
            if let mode = host.readerMode {
                presentReader(url: url, mode: mode, outcome: outcome)
            } else if let installNote {
                presentInteropPrompt(
                    kind: installNote,
                    terminal: { [weak host] in host?.confirmSavedThenComplete() })
            } else {
                host.completeSilently()
            }

        case let .product(product, _):
            // Persist the tracker, then present the SAME price-tracking editor the
            // main app shows (the extension host wraps it in Done chrome).
            presentPriceEditor(product: product, url: url)

        case let .video(platform, itemID):
            persistPlatform(platform, itemID: itemID, url: url)
            presentNonTextual(.platform(platform, itemID: itemID), url: url, installNote: installNote)

        case let .social(platform, itemID):
            persistPlatform(platform, itemID: itemID, url: url)
            presentNonTextual(.platform(platform, itemID: itemID), url: url, installNote: installNote)

        case .document:
            if host.readerMode != nil {
                host.confirmSavedThenComplete()
            } else if let installNote {
                presentInteropPrompt(
                    kind: installNote,
                    terminal: { [weak host] in host?.confirmSavedThenComplete() })
            } else {
                host.completeSilently()
            }

        case let .needsArchive(title):
            presentArchive(url: url, title: title)

        case .failed:
            // NEVER a misleading "Saved": surface the failure (action ext) / complete
            // quietly (share ext) — the app retries in the background either way.
            if host.readerMode != nil {
                host.failOrComplete("Couldn't load this link.")
            } else {
                store.item(forURLString: url.absoluteString).map { store.markFailed($0.id) }
                host.completeSilently()
            }
        }
    }

    // MARK: - Interop gate (cross-app purchase)

    /// Deletes the pending placeholder row appended before classification, so a
    /// blocked cross-surface save leaves NOTHING behind. `store.delete` also
    /// removes every on-disk artifact the row owns — including an imported
    /// document's copied `Articles/<id>-source.<ext>` file.
    private func discardBlockedSave(url: URL, itemID: UUID?) {
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

    /// Presents the interop prompt in the host's modal chrome. `terminal` runs
    /// when the user is done: `completeSilently` for a blocked save (nothing
    /// was saved — never a "Saved" checkmark), `confirmSavedThenComplete` for
    /// the informational install note (the item IS saved).
    private func presentInteropPrompt(kind: InteropPromptKind, terminal: @escaping () -> Void) {
        guard let host else { return }
        let prompt = InteropPromptViewController(
            kind: kind,
            context: .extensionHost(openURL: { [weak host] url in host?.openURL(url) }),
            currentSurface: currentSurface)
        prompt.onDone = terminal
        host.presentModally(prompt)
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
    /// choose the media download. Non-downloadable items retain the share extension's
    /// silent-save behavior — except when a paid cross-surface save needs the
    /// informational install note (`installNote`), which replaces that silent
    /// ending (the item is saved either way; `autoDownloadThenComplete` is a
    /// checkmark-only no-op for a non-downloadable URL, so nothing is lost).
    private func presentNonTextual(
        _ content: NonTextualContent, url: URL, installNote: InteropPromptKind? = nil
    ) {
        guard let host else { return }
        if host.readerMode != nil || MediaDownloadablePlatform.supports(url.absoluteString) {
            let saved = SavedNonTextualViewController(
                articleURLString: url.absoluteString, content: content) { [weak host] in
                host?.confirmSavedThenComplete()
            }
            host.presentModally(saved)
        } else if let installNote {
            presentInteropPrompt(
                kind: installNote,
                terminal: { [weak host] in host?.confirmSavedThenComplete() })
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
