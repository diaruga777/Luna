//
//  ShareSurfaceDriver.swift
//  ShareKit
//

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
/// (`host.isActionExtension` / `host.readerMode`), never divergent logic — both call
/// the same pipeline and the same exhaustive `Outcome` switch here. Every case
/// PERSISTS the classified metadata to the shared store (so an extension save is
/// shaped identically to a main-app save — the fix for the YouTube-via-share bug,
/// where a `.video` used to be dropped to a bare URL the main app had to
/// re-classify) and presents real UI; `.failed` shows an error, never "Saved".
@MainActor
final class ShareSurfaceDriver {

    private weak var host: ExtensionHost?
    private let store: ReadingListStore
    /// Injectable so tests can drive the pipeline with a mock fetcher / fixtures and
    /// a nil render tier (extension-safe). Production uses the live defaults.
    private let process: (IngestInput) async -> Outcome

    init(
        host: ExtensionHost,
        store: ReadingListStore = .shared,
        process: @escaping (IngestInput) async -> Outcome = { await IngestPipeline.process($0) }
    ) {
        self.host = host
        self.store = store
        self.process = process
    }

    /// Runs the shared pipeline for the just-appended `originalURL`, repoints the saved
    /// item if the pipeline unwrapped to a different URL (so the main app extracts the
    /// real article), then presents + persists the `Outcome` via this surface's host.
    func ingestAndPresent(originalURL: URL) async {
        let isAction = host?.isActionExtension == true
        let outcome = await process(IngestInput(
            url: originalURL, source: isAction ? .appIntent : .shareSheet))

        // Repoint the just-saved item if the pipeline unwrapped to a different URL.
        let unwrapped = await URLUnwrapper.unwrap(originalURL)
        let url = unwrapped.didUnwrap ? unwrapped.url : originalURL
        if unwrapped.didUnwrap, let item = store.item(forURLString: originalURL.absoluteString) {
            _ = store.updateURL(url.absoluteString, for: item.id)
        }
        present(outcome, url: url)
    }

    /// The EXHAUSTIVE per-surface presenter over the unified `Outcome` (no `default`,
    /// compiler-checked). Public so the fixture can drive it directly with any Outcome.
    func present(_ outcome: Outcome, url: URL) {
        guard let host else { return }
        switch outcome {
        case let .article(content, _):
            persistArticle(content, url: url)
            if let mode = host.readerMode {
                presentReader(url: url, mode: mode, outcome: outcome)
            } else {
                host.confirmSavedThenComplete()
            }

        case let .product(product, _):
            // Persist the tracker, then present the SAME price-tracking editor the
            // main app shows (the extension host wraps it in Done chrome). Previously
            // both extensions only saved silently + showed a checkmark.
            presentPriceEditor(product: product, url: url)

        case let .video(platform, itemID):
            persistPlatform(platform, service: nil, itemID: itemID, url: url)
            presentNonTextual(.youTube(videoID: itemID ?? ""), url: url)

        case let .social(platform, itemID):
            persistPlatform(platform, service: nil, itemID: itemID, url: url)
            presentNonTextual(.platform(platform, itemID: itemID), url: url)

        case let .audio(platform, service, itemID):
            persistPlatform(platform, service: service, itemID: itemID, url: url)
            presentNonTextual(.platform(platform, itemID: itemID), url: url)

        case .document:
            host.confirmSavedThenComplete()

        case let .needsArchive(title):
            presentArchive(url: url, title: title)

        case .failed:
            // NEVER a misleading "Saved": surface the failure (action ext) / complete
            // quietly (share ext) — the app retries in the background either way.
            if host.readerMode != nil {
                host.failOrComplete("Couldn't load this link.")
            } else {
                store.item(forURLString: url.absoluteString).map { store.markFailed($0.id) }
                host.confirmSavedThenComplete()
            }
        }
    }

    // MARK: - Store writes (shared shape with the main app's IngestorOutcomePresenter)

    private func persistArticle(_ content: ArticleContent, url: URL) {
        guard let saved = store.item(forURLString: url.absoluteString) else { return }
        _ = store.saveContent(content, for: saved)
    }

    /// Persists a recognized video/social/audio item's classification (platform + item
    /// id), so the saved item renders correctly and the main app doesn't re-classify a
    /// bare URL. YouTube is recorded as a `.youtube` platform item with its video id;
    /// the main app fills in oEmbed title/thumbnail on next launch.
    private func persistPlatform(
        _ platform: ContentPlatform, service: MusicProvider?, itemID: String?, url: URL
    ) {
        guard let saved = store.item(forURLString: url.absoluteString) else { return }
        if platform == .youtube, let videoID = itemID {
            _ = store.saveYouTubeMetadata(
                videoID: videoID, title: saved.title ?? platform.displayName,
                channelName: nil, thumbnailFileName: nil, for: saved.id)
        } else {
            _ = store.savePlatformMetadata(
                platform: platform, platformItemID: itemID, title: nil, creator: nil,
                thumbnailFileName: nil, mediaCreatorName: nil, mediaItemTitle: nil,
                mediaSourceService: service, for: saved.id)
        }
    }

    @discardableResult
    private func persistTracker(_ product: ProductInfo, url: URL) -> UUID? {
        guard let saved = store.item(forURLString: url.absoluteString) else { return nil }
        let tracker = PriceTracker(
            productName: product.name, firstStoreURL: url.absoluteString,
            price: product.priceAmount, currency: product.priceCurrency,
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

    /// Routes a non-textual outcome: the action extension shows the saved-content
    /// screen (so the reader VC never sees a video); the share extension takes the
    /// auto-download path (the metadata is already persisted above).
    private func presentNonTextual(_ content: NonTextualContent, url: URL) {
        guard let host else { return }
        if host.readerMode != nil {
            let saved = SavedNonTextualViewController(
                articleURLString: url.absoluteString, content: content) { [weak host] in
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

    /// A paywalled article: the action extension opens its in-sheet reader (which runs
    /// the archive-CAPTCHA flow and swaps to the native reader on extract); the zero-UI
    /// share extension opens the archive reader directly, confirming on extract.
    private func presentArchive(url: URL, title: String) {
        guard let host else { return }
        if let mode = host.readerMode {
            presentReader(url: url, mode: mode, outcome: .needsArchive(title: title))
            return
        }
        guard let saved = store.item(forURLString: url.absoluteString) else {
            host.confirmSavedThenComplete()
            return
        }
        store.markNeedsCaptcha(saved.id, title: title)
        let archive = ArchiveWebReaderViewController(articleURL: url, itemID: saved.id)
        archive.onClose = { [weak host] in host?.confirmSavedThenComplete() }
        archive.onExtracted = { [weak host] in host?.confirmSavedThenComplete() }
        host.presentModally(archive)
    }
}
