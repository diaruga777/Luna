//
//  URLRescueWiring.swift
//  Luna
//

import Foundation
import LunaHTMLClassification
import LunaModels
import LunaSaves
import LunaSavesUI
import LunaStorage
import LunaURLRescue
import UIKit

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

/// The ONLY place the app links `LunaURLRescue`. Installs the engine bridge
/// into `URLRescueCoordinator`, plus the rescue trigger the ingestor calls.
/// Runs in all four apps — rescue is universal, automatic and silent, and no
/// surface asks for it or supplies a content kind. The media leg is a per-kind
/// seam the `KindWiring` variants fill (`mediaRescueStarter`). See
/// `claudedocs/url-rescue.md`.
enum URLRescueWiring {

    /// The engine's social-media asset resolver, installed by media-handling
    /// apps' KindWiring (`LunaMediaDownload.SocialMediaResolver`); nil (Reader,
    /// Price Tracker) leaves the engine's media directives asset-less, so a
    /// media rescue stays unrescuable there. `KindWiring` installs this before
    /// `install()` runs, so it's read exactly once, there.
    static var mediaResolver: SocialMediaResolving?

    static var mediaRescueStarter: (any MediaRescueStarting)?

    @MainActor
    static func install() {
        let engine: URLRescueEngine
        if let mediaResolver {
            engine = URLRescueEngine(mediaResolver: mediaResolver)
        } else {
            engine = URLRescueEngine()
        }

        URLRescueCoordinator.engine = EngineBridge(engine: engine)
        URLRescueCoordinator.shared.install()

        // Reader/Downloader failures are handed to the coordinator by the ingestor
        // (rescueTrigger). Extensions never install this, so a failure just stays
        // failed.
        SavesIngestor.rescueTrigger = CoordinatorRescueTrigger()

        // A recovery Luna file's recipe is replayed through the same machinery
        // below the model — the same host policy, the same directive applier,
        // the same rule store. An extension links none of it and keeps
        // `NoRecipeReplay`, which is why this is a witness.
        RecoveryFileApplier.recipeReplay = RecoveryRecipeReplay()

        // An extension adopted a recovery file's content and kept its recipe.
        // Replaying it here teaches the host rule the extension could not, and
        // the save it came with is already recovered — so the result is
        // discarded on purpose.
        drainPendingRecipes()
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in drainPendingRecipes() }
    }

    private static func drainPendingRecipes() {
        let rows = PendingRecoveryRecipeStore.shared.takeAll()
        guard !rows.isEmpty else { return }
        let runner = RecoveryRecipeRunner()
        Task {
            for row in rows {
                guard let recipe = row.recipe, let pageURL = row.pageURL else { continue }
                _ = await runner.run(recipe, pageURL: pageURL)
            }
        }
    }

    /// Replays a recovery file's recipe and persists what it produced. Success
    /// means the save is ready AND the host rule is learned, so the site's next
    /// failure needs no model and no chat.
    private final class RecoveryRecipeReplay: RecoveryRecipeReplaying {
        private let runner = RecoveryRecipeRunner()

        var canReplay: Bool { true }

        func replay(
            _ recipe: LunaRecoveryRecipe, pageURL: URL, itemID: UUID
        ) async -> Bool {
            guard let result = await runner.run(recipe, pageURL: pageURL) else { return false }
            return await SavesIngestor.shared.applyRescued(
                result, forItemID: itemID, interactive: false)
        }
    }

    /// The coordinator's half of the bridge: the availability gate and one
    /// rescue run over the app-shell `perform` below.
    private struct EngineBridge: URLRescueEngineBridging {
        let engine: URLRescueEngine

        var isRescueAvailable: Bool { engine.isAvailable }

        func performRescue(for item: SavedItem) async -> URLRescueCoordinator.RescueRunResult {
            await URLRescueWiring.perform(engine: engine, item: item)
        }
    }

    /// A failed first pass reaches the coordinator, which re-reads the item from
    /// the store by id.
    private struct CoordinatorRescueTrigger: IngestRescueTriggering {
        func itemFailedIngest(itemID: UUID, url: URL, source: CaptureSource) {
            URLRescueCoordinator.shared.itemJustFailed(itemID, source: source)
        }
    }

    // MARK: - Perform (coordinator bridge)

    private static func perform(
        engine: URLRescueEngine, item: SavedItem
    ) async -> URLRescueCoordinator.RescueRunResult {
        guard let url = item.url else { return .notRecovered }
        let record = SaveFailureStore.shared.record(for: item.id)
        // Everything that travels here is EVIDENCE, not instruction: the item id
        // (the key into the per-save diagnostic trace), the recorded failure
        // reason, the best title Luna recovered, and whether the browser handoff
        // has already been offered. The model classifies the page itself.
        let request = RescueRequest(
            url: url, source: item.effectiveCaptureSource,
            failureKind: failureKind(for: item),
            itemID: item.id,
            failureReason: record?.reason,
            pageTitle: record?.resolvedTitle ?? item.title,
            browserHandoffTried: RescueLedgerStore.shared.hasHandedToBrowser(item.id))
        let outcome = await engine.rescue(request) { stage in
            URLRescueCoordinator.shared.reportProgress(item.id, stage: stage)
        }
        switch outcome {
        case .rescued(let result, _):
            let applied = await SavesIngestor.shared.applyRescued(
                result, forItemID: item.id, interactive: false)
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
            SavesStore.shared.markNeedsCaptcha(
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

    // MARK: - Failure kind

    /// What already went wrong, for the prompt's diagnostic line. It is read off
    /// the item — the recorded failure reason and the item's own shape are the
    /// only true evidence of which branch of the pipeline gave up — and it is a
    /// FACT handed to the model, never a steer toward one content type.
    private static func failureKind(for item: SavedItem) -> RescueRequest.FailureKind {
        let reason = SaveFailureStore.shared.record(for: item.id)?.reason
        switch SaveFailureReason.attemptKind(for: item, reason: reason) {
        case .article: return .articleFailed
        case .product: return .productNoPrice
        case .media: return .mediaNoAssets
        }
    }
}
