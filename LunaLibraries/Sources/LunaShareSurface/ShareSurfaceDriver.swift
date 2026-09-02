//
//  ShareSurfaceDriver.swift
//  ShareKit
//

import LunaDesignSystem
import LunaStorage
import LunaIngest
import LunaModels
import LunaHTMLClassification
import LunaURLClassification
import UIKit

/// An extension's diagnostics stream: the SYNCHRONOUS logger, because an
/// extension can be jetsammed the instant it finishes and an async queue hop
/// would lose the tail of the story (`claudedocs/save-diagnostics.md`).
struct SharedDiagnosticsMirror: SaveDiagnosticsMirroring {
    func mirror(message: String, category: String) {
        SharedDiagnosticLog.record(message, category: category)
    }
}

/// The host-agnostic ingest-and-present flow for the share/action extension
/// surfaces.
///
/// It runs the one shared `IngestPipeline` for an appended URL and presents
/// the resulting `Outcome` through an injected `ExtensionHost`, so the whole
/// flow is testable with a fake host. The real `NSExtensionContext` harness
/// is not testable this way — a simulator cannot drive the share sheet, and
/// `completeRequest`/`inputItems` have no test seam. The real
/// `ShareViewController` is a thin adapter that conforms to `ExtensionHost`
/// and owns only attachment loading and the live UIKit chrome; this driver
/// owns the decision, persistence, and presentation logic that must stay
/// identical across every surface.
///
/// The share extension and the action extension differ only in data
/// (`host.isActionExtension` / `host.readerMode`), never in processing
/// logic — both call the same pipeline and the same exhaustive `Outcome`
/// switch here. Every case persists the classified metadata to the shared
/// store, so an extension save is shaped identically to a main-app save.
/// Presentation policy stays narrow: the action extension shows its
/// reader/saved UI, while the share extension only presents media, price,
/// and archive-bypass UI.

/// The ingest pipeline, as a share surface calls it. Production runs the
/// one shared `IngestPipeline`; a test substitutes fixtures with a mock
/// fetcher and no render tier, keeping it extension-safe.
public protocol ShareIngestProcessing {
    func process(_ input: IngestInput) async -> IngestResult
}

/// The production leg: the shared pipeline, post-resolution.
public struct SharedIngestPipelineProcessor: ShareIngestProcessing {
    public init() {}

    public func process(_ input: IngestInput) async -> IngestResult {
        await IngestPipeline.processResolved(input)
    }
}

/// The per-app content gate over a classified outcome (`SurfaceSupport`): a
/// single-content app's extension drops foreign kinds.
public protocol ShareSurfaceGating {
    func decision(for outcome: Outcome) -> SurfaceSupport.Decision
}

/// The production gate: the app this extension is actually running in.
public struct CurrentProcessSurfaceGate: ShareSurfaceGating {
    public init() {}

    public func decision(for outcome: Outcome) -> SurfaceSupport.Decision {
        SurfaceSupport.evaluateForCurrentProcess(owner: outcome.owningApp)
    }
}

@MainActor
public final class ShareSurfaceDriver {

    private weak var host: ExtensionHost?
    private let store: SavesStore
    private let ingest: ShareIngestProcessing
    private let surfaceGate: ShareSurfaceGating
    /// The app the extension is running in, for the error copy + deep links.
    private let currentApp: LunaApp
    /// This request's diagnostic trace, created in `ingestAndPresent` and
    /// read back by `present`'s failure leg. This is held as a property,
    /// not passed as a parameter, because `present` is also the fixture's
    /// direct entry point: a driver built for a single `Outcome` simply has
    /// none, and records nothing.
    private var recorder: SaveDiagnosticsRecorder?

    public init(
        host: ExtensionHost,
        store: SavesStore = .shared,
        ingest: ShareIngestProcessing = SharedIngestPipelineProcessor(),
        surfaceGate: ShareSurfaceGating = CurrentProcessSurfaceGate(),
        currentApp: LunaApp = .current
    ) {
        self.host = host
        self.store = store
        self.ingest = ingest
        self.surfaceGate = surfaceGate
        self.currentApp = currentApp
    }

    /// Runs the shared pipeline for the just-appended `originalURL`, repoints the saved
    /// item to the pipeline's resolved URL, then presents + persists the `Outcome` via
    /// this surface's host.
    public func ingestAndPresent(originalURL: URL, page: CapturedPage = .none) async {
        // Keeps the identity of this extension request's placeholder.
        // Resolution can discover that its canonical URL is already saved
        // and delete the placeholder; a later blocked decision must never
        // then delete that pre-existing canonical item merely because it
        // has the resolved URL.
        let pendingItemID = store.item(forURLString: originalURL.absoluteString)?.id
        // The same per-save trace the app records, mirrored through the
        // synchronous logger. An extension can be jetsammed the instant it
        // finishes, so an async queue hop would lose the tail of the story
        // (`claudedocs/save-diagnostics.md`).
        let recorder = pendingItemID.map { itemID in
            SaveDiagnosticsRecorder(itemID: itemID, mirror: SharedDiagnosticsMirror())
        }
        self.recorder = recorder
        recorder?.record(
            "ingest: begin \(SaveDiagnostics.url(originalURL)) source=shareSheet"
                + (page.html.map { " prefetchedHTML=\($0.count)ch" } ?? ""),
            category: "ingest")
        let result = await SaveDiagnostics.$recorder.withValue(recorder) {
            await ingest.process(IngestInput(
                url: originalURL, source: .shareSheet, page: page))
        }

        let url = result.url
        if url != originalURL, let item = store.item(forURLString: originalURL.absoluteString) {
            // The item was saved keyed on the pre-resolve (wrapper or
            // shortener) URL, but the pipeline resolved it to the publisher
            // URL. If that publisher URL is already saved (shared once
            // directly, once via apple.news), repointing would create two
            // items at the same URL. Instead this drops the wrapper item
            // and keeps the existing one, so the same article never
            // duplicates.
            if let existing = store.item(forURLString: url.absoluteString), existing.id != item.id {
                store.delete(item)
            } else {
                _ = store.updateURL(url.absoluteString, for: item.id)
            }
        }
        present(
            result.outcome, url: url, blockedItemID: pendingItemID,
            pluginID: result.pluginID)
    }

    /// The exhaustive per-surface presenter over the unified `Outcome` (no
    /// `default`, so the compiler checks every case). Public so the fixture
    /// can drive it directly with any `Outcome`.
    ///
    /// The per-app content gate runs first, before any persist. A
    /// foreign-kind outcome deletes the pending row `ShareViewController`
    /// appended before classification — including its copied document
    /// file, through `store.delete`'s `removeFiles` — so nothing remains in
    /// the store, and the generic unsupported-kind error is presented
    /// instead of any save UI, never a "Saved" checkmark. A supported
    /// outcome, or `.failed`'s nil owner, persists and presents normally.
    public func present(
        _ outcome: Outcome, url: URL, blockedItemID: UUID? = nil, pluginID: String? = nil
    ) {
        guard let host else { return }

        if case let .unsupported(owner) = surfaceGate.decision(for: outcome) {
            discardDiagnostics(url: url)
            discardUnsupportedSave(url: url, itemID: blockedItemID)
            presentUnsupportedError(owner: owner)
            return
        }

        // Anything that isn't a failure sheds its trace here, including a
        // save that succeeded on a retry of an item that had failed
        // before — otherwise that case would keep exporting a stale story.
        if case .failed = outcome {} else { discardDiagnostics(url: url) }

        // A plugin-produced save carries its owner from here on, so a later
        // refresh or re-resolution in the app reaches the same plugin.
        if let pluginID, let item = store.item(forURLString: url.absoluteString) {
            store.setPluginID(pluginID, for: item.id)
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
            // Persists the tracker, then presents the same price-tracking
            // editor the main app shows, wrapped in the extension host's
            // Done chrome.
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

        case let .failed(reason):
            // Never shows a misleading "Saved". Marks the row failed so the
            // main app's list shows it, records the failure reason and
            // count so the card and the rescue's failure-kind mapping can
            // read them, then offers the Apple-Intelligence rescue
            // hand-off: the action extension (which has UI) presents the
            // rescue card, while the zero-UI share extension completes
            // quietly (the main app's background sweep still rescues it if
            // auto-rescue is on).
            if let item = store.item(forURLString: url.absoluteString) {
                store.markFailed(item.id)
                SaveFailureStore.shared.recordFailure(item.id, reason: reason)
                flushDiagnostics(itemID: item.id, reason: reason)
            }
            if host.readerMode != nil {
                presentRescueFailure(url: url)
            } else {
                host.completeSilently()
            }

        case let .unsupported(owner):
            // The surface gate above discards an unsupported outcome
            // before this switch runs, so reaching here is a programming
            // error. This is loud in debug; in release, the row is marked
            // failed instead of left pending forever. Its trace is already
            // gone (the shed above covers every non-failure outcome), so
            // the shared log carries the reason instead. The assertion
            // stands down under XCTest so the suite can drive the recovery
            // it guards.
            if !LiveNetworkPolicy.isRunningUnderXCTest {
                assertionFailure("unsupported outcome reached the share presenter")
            }
            if let item = store.item(forURLString: url.absoluteString) {
                SharedDiagnosticLog.record(
                    "share: unsupported outcome (owner \(owner.storageIdentifier)) reached the "
                        + "presenter — marking \(item.id) failed",
                    category: "ingest")
                store.markFailed(item.id)
                SaveFailureStore.shared.recordFailure(item.id, reason: .unknown)
            }
            host.completeSilently()

        case let .locked(pluginID):
            // A plugin asked for a browser no extension can present. The save
            // is parked in the same lock a paywalled article gets, and the app
            // finishes it. The request row itself is written by the browser
            // bridge that deferred (§8.2).
            presentPluginLock(url: url, pluginID: pluginID)
        }
    }

    /// A plugin-locked save: park the row in the same `.needsCaptcha` lock the
    /// archive path parks in, and confirm the save. The extension shows no
    /// modal — only the app can present a plugin's browser step.
    private func presentPluginLock(url: URL, pluginID: String) {
        guard let host else { return }
        guard let saved = store.item(forURLString: url.absoluteString) else {
            host.confirmSavedThenComplete()
            return
        }
        store.markPluginLocked(saved.id, pluginID: pluginID, title: saved.title)
        host.confirmSavedThenComplete()
    }

    /// The action-extension failure card: shows the page, writes a
    /// pending-rescue record, and best-effort opens the containing app. The
    /// extension links no rescue engine — only the pending-record store
    /// and the deep link.
    ///
    /// The record carries no hint. The model classifies the page when the
    /// app drains the queue, so this card asks the user nothing.
    private func presentRescueFailure(url: URL) {
        guard let host else { return }
        let app = currentApp
        let card = RescueFailureViewController(
            url: url,
            rescueURL: LunaDeepLink.rescueLink(scheme: app.deepLinkScheme),
            delegate: RescueFailureCardLegs(host: host, url: url, app: app))
        host.presentModally(card)
    }

    // MARK: - Diagnostics

    /// Writes this request's buffered trace into the item's sidecar under
    /// an attempt separator, so the failed card in the main app can show
    /// it. This matches the shape `SavesIngestor.flushDiagnostics` writes,
    /// so an item that failed in the extension and again on the app's
    /// launch sweep ends up with both attempts in one file.
    private func flushDiagnostics(itemID: UUID, reason: SaveFailureReason?) {
        guard let recorder else { return }
        let lines = recorder.drainLines()
        guard !lines.isEmpty else { return }
        let attempt = SaveFailureStore.shared.record(for: itemID)?.failureCount ?? 1
        let separator = "— attempt \(attempt) via shareSheet, "
            + (reason.map { String(describing: $0) } ?? "unknown") + " —"
        SaveDiagnosticsStore.shared.appendLines([separator] + lines, for: itemID)
    }

    /// Drops the buffer and any file an earlier attempt left, for every
    /// outcome that isn't a failure.
    private func discardDiagnostics(url: URL) {
        _ = recorder?.drainLines()
        let itemID = store.item(forURLString: url.absoluteString)?.id ?? recorder?.itemID
        guard let itemID else { return }
        SaveDiagnosticsStore.shared.delete(for: itemID)
    }

    // MARK: - Per-kind presenter lookup

    /// The per-kind presenters, required after the surface gate has
    /// admitted the outcome. An admitted kind whose presenter isn't
    /// registered is a composition-root programming error, since the entry
    /// class registers presenters for exactly the kinds `SurfaceSupport`
    /// admits, so this asserts and completes silently instead of
    /// presenting the wrong surface.
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

    /// Deletes the pending placeholder row appended before classification,
    /// so a dropped foreign-kind save leaves nothing behind. `store.delete`
    /// also removes every on-disk artifact the row owns, including an
    /// imported document's copied `Articles/<id>-source.<ext>` file.
    private func discardUnsupportedSave(url: URL, itemID: UUID?) {
        if let itemID {
            // If wrapper dedup already removed this request's placeholder,
            // the correct blocked cleanup is a no-op. This must not fall
            // back to a URL lookup: that URL belongs to the older,
            // legitimate save.
            guard let item = store.item(withID: itemID) else { return }
            store.delete(item)
            return
        }
        guard let item = store.item(forURLString: url.absoluteString) else { return }
        store.delete(item)
    }

    /// Presents the shared unsupported-kind card, the same one the app
    /// shows, in the host's modal chrome. Done completes silently: nothing
    /// was saved, so no "Saved" checkmark ever appears.
    private func presentUnsupportedError(owner: LunaApp) {
        guard let host else { return }
        let error = UnsupportedSaveCardViewController(owner: owner, currentApp: currentApp)
        error.delegate = host
        host.presentModally(error)
    }

    // MARK: - Store writes (shared shape with the main app's IngestorOutcomePresenter)

    private func persistArticle(
        _ content: ArticleContent, html: String, url: URL, presenter: ShareArticlePresenting
    ) {
        guard let saved = store.item(forURLString: url.absoluteString) else { return }
        let savedWithContent = store.saveContent(content, for: saved)
        // The article-kind extras — a heuristics-only audio script, a
        // best-effort web archive of the same unlocked HTML, and the cover
        // thumbnail — live in the article presenter. This kind-neutral
        // module links none of that LunaReaderUI/LunaArchiveReader/
        // LunaAudioPlayback code.
        presenter.persistArticleExtras(
            item: savedWithContent, content: content, html: html, url: url, store: store)
    }

    /// Persists a recognized video/social item's classification.
    private func persistPlatform(
        _ platform: ContentPlatform, itemID: String?, url: URL
    ) {
        guard let saved = store.item(forURLString: url.absoluteString) else { return }
        _ = store.savePlatformMetadata(
            platform: platform, platformItemID: itemID, title: nil,
            thumbnailFileName: nil, for: saved.id)
    }

    // The product-kind store write lives in the kind-neutral
    // `SavesStore.savePriceTracker(_:forURLString:)` (LunaStorage) +
    // `ProductInfo.makeTracker(fallbackURL:)` (LunaHTMLClassification), shared
    // by `ExtensionProductPresenter` (the editor flow) and
    // `ShareReaderViewController` (which reaches the same write when it runs
    // the pipeline standalone).

    // MARK: - Presentation

    /// A paywalled article: every surface opens the same archive-CAPTCHA
    /// reader, URL pre-filled, identically to the main app, so the
    /// presentation intent matches across surfaces. The store markings
    /// stay here; the reader UI, and the on-extract swap to the in-sheet
    /// native reader, belong to the article presenter.
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

/// The failure card's three host legs, kept together for the life of the
/// card.
///
/// This is a small coordinator, not the driver itself: `ShareSurfaceDriver`
/// is a temporary object the save flow awaits and drops, while the card
/// stays on screen until the user answers it. The card retains this
/// coordinator, which holds the host weakly, so nothing cycles.
@MainActor
private final class RescueFailureCardLegs: RescueFailureCardDelegate {
    private weak var host: (any ExtensionHost)?
    private let url: URL
    private let app: LunaApp

    init(host: any ExtensionHost, url: URL, app: LunaApp) {
        self.host = host
        self.url = url
        self.app = app
    }

    func rescueFailureCardDidRequestRescue(_ card: RescueFailureViewController) {
        PendingRescueRequestStore.shared.append(PendingRescueRequest(
            urlString: url.absoluteString, hint: nil, dateWritten: Date(),
            sourceSurface: app.storageIdentifier))
    }

    func rescueFailureCard(_ card: RescueFailureViewController, openApp url: URL) {
        host?.openURL(url)
    }

    func rescueFailureCardDidFinish(_ card: RescueFailureViewController) {
        host?.completeSilently()
    }
}
