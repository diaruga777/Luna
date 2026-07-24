//
//  ShareSurfaceDriver.swift
//  ShareKit
//

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
            guard let article = Self.requireArticlePresenter(host: host) else { return }
            persistArticle(content, html: html, url: url, presenter: article)
            if let mode = host.readerMode {
                article.presentReader(url: url, mode: mode, outcome: outcome, host: host)
            } else {
                host.completeSilently()
            }

        case let .product(product, _):
            // Persist the tracker, then present the SAME price-tracking editor the
            // main app shows (the extension host wraps it in Done chrome).
            guard let productPresenter = Self.requireProductPresenter(host: host) else { return }
            productPresenter.presentPriceEditor(product: product, url: url, store: store, host: host)

        case let .video(platform, itemID):
            persistPlatform(platform, itemID: itemID, url: url)
            guard let media = Self.requireMediaPresenter(host: host) else { return }
            media.presentNonTextual(urlString: url.absoluteString, host: host)

        case let .social(platform, itemID):
            persistPlatform(platform, itemID: itemID, url: url)
            guard let media = Self.requireMediaPresenter(host: host) else { return }
            media.presentNonTextual(urlString: url.absoluteString, host: host)

        case .document:
            if host.readerMode != nil {
                host.confirmSavedThenComplete()
            } else {
                host.completeSilently()
            }

        case let .needsArchive(title):
            guard let article = Self.requireArticlePresenter(host: host) else { return }
            presentArchive(url: url, title: title, presenter: article)

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

        case .unsupported:
            // Unreachable: the surface gate above discards an unsupported
            // outcome before this switch runs.
            assertionFailure("unsupported outcome reached the share presenter")
            host.completeSilently()
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

    // MARK: - Per-kind presenter lookup

    /// The per-kind presenters, required AFTER the surface gate has admitted the
    /// outcome: an admitted kind whose presenter isn't registered is a
    /// composition-root programming error (the entry class registers presenters
    /// for exactly the kinds `SurfaceSupport` admits), so this asserts and
    /// completes silently rather than presenting a wrong surface.
    private static func requireArticlePresenter(host: ExtensionHost?) -> ShareArticlePresenting? {
        guard let presenter = ShareKindPresenters.article else {
            assertionFailure("article outcome admitted with no ShareKindPresenters.article")
            host?.completeSilently()
            return nil
        }
        return presenter
    }

    private static func requireMediaPresenter(host: ExtensionHost?) -> ShareMediaPresenting? {
        guard let presenter = ShareKindPresenters.media else {
            assertionFailure("media outcome admitted with no ShareKindPresenters.media")
            host?.completeSilently()
            return nil
        }
        return presenter
    }

    private static func requireProductPresenter(host: ExtensionHost?) -> ShareProductPresenting? {
        guard let presenter = ShareKindPresenters.product else {
            assertionFailure("product outcome admitted with no ShareKindPresenters.product")
            host?.completeSilently()
            return nil
        }
        return presenter
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

    private func persistArticle(
        _ content: ArticleContent, html: String, url: URL, presenter: ShareArticlePresenting
    ) {
        guard let saved = store.item(forURLString: url.absoluteString) else { return }
        let savedWithContent = store.saveContent(content, for: saved)
        // The article-kind extras — heuristics-only audio script, best-effort web
        // archive of the SAME unlocked HTML, and the cover thumbnail — live in the
        // article presenter (LunaReaderUI/LunaArchiveReader/LunaAudioPlayback code
        // this kind-neutral module no longer links).
        presenter.persistArticleExtras(
            item: savedWithContent, content: content, html: html, url: url, store: store)
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

    // The product-kind store write lives in the kind-neutral
    // `ReadingListStore.savePriceTracker(_:forURLString:)` (LunaStorage) +
    // `ProductInfo.makeTracker(fallbackURL:)` (LunaHTMLClassification), shared
    // by `ExtensionProductPresenter` (the editor flow) and
    // `ShareReaderViewController` (which reaches the same write when it runs
    // the pipeline standalone).

    // MARK: - Presentation

    /// A paywalled article: EVERY surface opens the same archive-CAPTCHA reader
    /// (URL pre-filled), identically to the main app, so the presentation intent
    /// matches across surfaces. The store markings stay here; the reader UI (and
    /// the on-extract swap to the in-sheet native reader) is the article
    /// presenter's.
    private func presentArchive(url: URL, title: String, presenter: ShareArticlePresenting) {
        guard let host else { return }
        guard let saved = store.item(forURLString: url.absoluteString) else {
            host.confirmSavedThenComplete()
            return
        }
        store.markNeedsCaptcha(saved.id, title: title)
        presenter.presentArchive(url: url, itemID: saved.id, store: store, host: host)
    }
}
