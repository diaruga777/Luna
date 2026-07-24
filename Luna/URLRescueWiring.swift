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
/// all three apps (rescue is universal); the default hint differs by surface,
/// and the media/product LEGS are per-kind seams filled by the `KindWiring`
/// variants (`mediaRescueStarter`; `rescueProductInfo` consumed by product
/// wirings for the price editor's "Ask Apple Intelligence" resolver). See
/// `claudedocs/url-rescue.md`.
enum URLRescueWiring {

    /// Media-kind rescue application: downloads the engine-resolved assets
    /// without re-running platform resolution. Installed by media apps'
    /// `KindWiring` (Downloader + central Luna); nil ⇒ a `.rescuedMedia`
    /// outcome stays unrescued (false).
    static var mediaRescueStarter: ((
        _ sourceURLString: String, _ title: String?, _ assets: [MediaAsset]
    ) async -> Bool)?

    /// The engine installed by `install()`, kept for the product-kind price
    /// resolver below (KindWiring runs before `install()`, so product wirings
    /// call through this accessor lazily rather than capturing the engine).
    private static var engine: URLRescueEngine?

    static func install() {
        let engine = URLRescueEngine()
        Self.engine = engine

        URLRescueCoordinator.engine = URLRescueCoordinator.Engine(
            isAvailable: { engine.isAvailable },
            perform: { item, hint, interactive in
                await perform(engine: engine, item: item, hint: hint, interactive: interactive)
            })
        URLRescueCoordinator.shared.install()

        // Reader/Downloader failures are handed to the coordinator by the ingestor
        // (rescueTrigger). Extensions never set this, so a failure just stays failed.
        ReadingListIngestor.rescueTrigger = { itemID, url, source, interactive in
            _ = url // the coordinator re-reads the item from the store by id
            URLRescueCoordinator.shared.itemJustFailed(itemID, source: source, interactive: interactive)
        }
    }

    /// Product-kind "no price" → "Ask Apple Intelligence" resolution (Phase 6
    /// UI). Product `KindWiring` variants wrap this into
    /// `PriceTrackingViewController.intelligentPriceResolver`.
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
    ) async -> Bool {
        guard let url = item.url else { return false }
        let resolvedHint = hint ?? defaultHint(for: AppSurfaceConfig.current)
        let request = RescueRequest(
            url: url, source: item.effectiveCaptureSource,
            failureKind: failureKind(for: resolvedHint),
            hint: contentHint(for: resolvedHint))
        let outcome = await engine.rescue(request)
        switch outcome {
        case .rescued(let result, _):
            return await ReadingListIngestor.shared.applyRescued(result, forItemID: item.id, interactive: interactive)
        case .rescuedMedia(let assets, _):
            // Download the engine-resolved assets without re-running platform
            // resolution (the source page already failed to resolve normally).
            // Media-kind apps install the starter; elsewhere the save stays failed.
            guard let mediaRescueStarter else { return false }
            return await mediaRescueStarter(url.absoluteString, item.title, assets)
        case .unrescuable, .unavailable, .quotaExhausted, .failed:
            return false
        }
    }

    // MARK: - Hint mapping

    static func defaultHint(for surface: AppSurface) -> RescueHint {
        switch surface {
        case .all, .reader: return .article
        case .downloader: return .media
        case .priceTracker: return .product
        }
    }

    private static func failureKind(for hint: RescueHint) -> RescueRequest.FailureKind {
        switch hint {
        case .article: return .articleFailed
        case .product: return .productNoPrice
        case .media: return .mediaNoAssets
        }
    }

    private static func contentHint(for hint: RescueHint) -> RescueRequest.ContentHint {
        switch hint {
        case .article: return .article
        case .product: return .product
        case .media: return .media
        }
    }
}
