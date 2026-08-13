//
//  URLRescueWiring.swift
//  Luna
//

import Foundation
import LunaHTMLClassification
import LunaModels
import LunaReadingList
import LunaReadingListUI
import LunaStorage
import LunaURLRescue

/// The ONLY place the app links `LunaURLRescue`. Installs the engine bridge into
/// `URLRescueCoordinator`, plus the rescue trigger the ingestor calls. Runs in
/// all four apps (rescue is universal); no surface supplies a content hint any
/// more — the model classifies the page — and the media/product LEGS are per-kind seams filled by the `KindWiring`
/// variants (`mediaRescueStarter`; `rescueProductInfo` consumed by product
/// wirings for the price editor's "Ask Apple Intelligence" resolver). See
/// `claudedocs/url-rescue.md`.
/// Downloads the engine-resolved assets of a media rescue without re-running
/// platform resolution (the source page already failed to resolve normally).
/// Installed by media apps' `KindWiring` (Downloader + central Luna); left
/// uninstalled ⇒ a `.rescuedMedia` outcome stays unrescued.
protocol MediaRescueStarting {
    /// Whether the download really started.
    func startMediaRescue(
        sourceURLString: String, title: String?, assets: [MediaAsset]
    ) async -> Bool
}

enum URLRescueWiring {

    /// The engine's social-media asset resolver, installed by media-handling
    /// apps' KindWiring (`LunaMediaDownload.SocialMediaResolver`); nil (Reader,
    /// Price Tracker) leaves the engine's media directives asset-less, so a
    /// media rescue stays unrescuable there. `KindWiring` installs this before
    /// `install()` runs, so it's read exactly once, there.
    static var mediaResolver: SocialMediaResolving?

    static var mediaRescueStarter: (any MediaRescueStarting)?

    /// The engine installed by `install()`, kept for the product-kind price
    /// resolver below (KindWiring runs before `install()`, so product wirings
    /// call through this accessor lazily rather than capturing the engine).
    private static var engine: URLRescueEngine?

    static func install() {
        let engine: URLRescueEngine
        if let mediaResolver {
            engine = URLRescueEngine(mediaResolver: mediaResolver)
        } else {
            engine = URLRescueEngine()
        }
        Self.engine = engine

        URLRescueCoordinator.engine = EngineBridge(engine: engine)
        URLRescueCoordinator.shared.install()

        // Reader/Downloader failures are handed to the coordinator by the ingestor
        // (rescueTrigger). Extensions never install this, so a failure just stays
        // failed.
        ReadingListIngestor.rescueTrigger = CoordinatorRescueTrigger()
    }

    /// The coordinator's half of the bridge: the availability gate and one
    /// rescue run over the app-shell `perform` below.
    private struct EngineBridge: URLRescueEngineBridging {
        let engine: URLRescueEngine

        var isRescueAvailable: Bool { engine.isAvailable }

        func performRescue(
            for item: ReadingListItem, hint: RescueHint?, interactive: Bool
        ) async -> URLRescueCoordinator.RescueRunResult {
            await URLRescueWiring.perform(
                engine: engine, item: item, hint: hint, interactive: interactive)
        }
    }

    /// A failed first pass reaches the coordinator, which re-reads the item from
    /// the store by id.
    private struct CoordinatorRescueTrigger: IngestRescueTriggering {
        func itemFailedIngest(
            itemID: UUID, url: URL, source: CaptureSource, interactive: Bool
        ) {
            URLRescueCoordinator.shared.itemJustFailed(
                itemID, source: source, interactive: interactive)
        }
    }

    /// Product-kind "no price" → "Ask Apple Intelligence" resolution (Phase 6
    /// UI). Product `KindWiring` variants wrap this into
    /// `ProductPriceRescue.resolver`.
    static func rescueProductInfo(urlString: String) async -> ProductInfo? {
        guard let engine, let url = URL(string: urlString) else { return nil }
        let request = RescueRequest(url: url, source: .manual, failureKind: .productNoPrice, hint: .product)
        let outcome = await engine.rescue(request)
        guard case .rescued(let result, _) = outcome, case .product(let info, _) = result.outcome else { return nil }
        return info
    }

    // MARK: - Perform (coordinator bridge)

    private static func perform(
        engine: URLRescueEngine, item: ReadingListItem, hint: RescueHint?, interactive: Bool
    ) async -> URLRescueCoordinator.RescueRunResult {
        guard let url = item.url else { return .notRecovered }
        let record = SaveFailureStore.shared.record(for: item.id)
        // No hint means the MODEL classifies the page — the failed-save
        // card sends nil, and so does every automatic path. Only a surface that
        // genuinely knows the kind (the price editor, the media card) passes one.
        //
        // The rest of what travels here is EVIDENCE, not instruction: the item id
        // (the key into the per-save diagnostic trace), the recorded failure
        // reason, the best title Luna recovered, and whether the browser handoff
        // has already been offered.
        let request = RescueRequest(
            url: url, source: item.effectiveCaptureSource,
            failureKind: failureKind(for: item, hint: hint),
            hint: hint,
            itemID: item.id,
            failureReason: record?.reason,
            pageTitle: record?.resolvedTitle ?? item.title,
            browserHandoffTried: RescueLedgerStore.shared.hasHandedToBrowser(item.id))
        let outcome = await engine.rescue(request) { stage in
            URLRescueCoordinator.shared.reportProgress(item.id, stage: stage)
        }
        switch outcome {
        case .rescued(let result, _):
            let applied = await ReadingListIngestor.shared.applyRescued(
                result, forItemID: item.id, interactive: interactive)
            if applied { return .advanced }
            // The model DID recover the content and this app's surface dropped it
            // on the way in (a Reader rescuing a product page, say). That is not
            // the user's one attempt to lose, and it reads as an outright failure
            // in the log unless it is named.
            DiagnosticLog.shared.record(
                "apply outcome=surface-dropped host=\(url.host ?? "?")", category: "rescue")
            return .surfaceDropped
        case .rescuedMedia(let assets, _):
            // Download the engine-resolved assets without re-running platform
            // resolution (the source page already failed to resolve normally).
            // Media-kind apps install the starter; elsewhere the save stays failed.
            guard let mediaRescueStarter else { return .surfaceDropped }
            return await mediaRescueStarter.startMediaRescue(
                sourceURLString: url.absoluteString, title: item.title, assets: assets)
                ? .advanced : .notRecovered
        case .needsBrowser:
            // Not a recovery, but not a dead end either: the item moves to the
            // interactive archive-unlock tier, which is a card the user can act
            // on. `markNeedsCaptcha` clears the failure sidecar itself.
            //
            // Only in an app that HAS that tier. `.needsCaptcha` is rendered by
            // the article deck, which the Downloader and the Price Tracker don't
            // compile — parking an item there would hide it in a state their
            // decks have no card for. `LinkImportRunner.articleUnlocker` is the
            // existing seam for exactly this question (the two article-handling
            // KindWirings install it), so the gate is the one already in use
            // rather than a second one that could disagree with it.
            guard LinkImportRunner.articleUnlocker != nil else {
                DiagnosticLog.shared.record(
                    "browser handoff declined (no unlock tier) host=\(url.host ?? "?")",
                    category: "rescue")
                return .notRecovered
            }
            RescueLedgerStore.shared.recordBrowserHandoff(item.id)
            ReadingListStore.shared.markNeedsCaptcha(
                item.id, title: record?.resolvedTitle ?? item.title)
            SaveDiagnosticsStore.shared.delete(for: item.id)
            return .advanced
        case .failed(.guardrailViolation):
            return .guardrailed
        case .unavailable, .quotaExhausted:
            return .transient
        case .failed(let error):
            if case .transientModel = error { return .transient }
            if case .rateLimited = error { return .transient }
            if case .networkFailure = error { return .transient }
            if case .serviceUnavailable = error { return .transient }
            return .notRecovered
        case .unrescuable:
            return .notRecovered
        }
    }

    // MARK: - Hint mapping

    /// What already went wrong, for the prompt's diagnostic line. With an explicit
    /// hint it follows the hint; otherwise it's read off the item — the recorded
    /// failure reason and the item's own shape are the only true evidence of which
    /// branch of the pipeline gave up, and under `.auto` this is a FACT handed to
    /// the model, never a steer toward one content type.
    private static func failureKind(
        for item: ReadingListItem, hint: RescueHint?
    ) -> RescueRequest.FailureKind {
        if let hint {
            switch hint {
            case .article: return .articleFailed
            case .product: return .productNoPrice
            case .media: return .mediaNoAssets
            }
        }
        if SaveFailureStore.shared.record(for: item.id)?.reason == .noMediaFound {
            return .mediaNoAssets
        }
        if item.isPriceTracker { return .productNoPrice }
        return .articleFailed
    }
}
