//
//  URLRescueWiring.swift
//  Luna
//

import Foundation
import LunaMediaDownload
import LunaModels
import LunaPriceUI
import LunaReadingList
import LunaReadingListUI
import LunaStorage
import LunaURLRescue

/// The ONLY place the app links `LunaURLRescue`. Installs the engine bridge into
/// `URLRescueCoordinator`, plus the price/media rescue closures the UI layers
/// call. Runs in all three apps (rescue is universal); the default hint differs
/// by surface. See `claudedocs/url-rescue.md`.
enum URLRescueWiring {

    /// A media applier the Downloader wires up (Phase 6) to turn rescued assets
    /// into a real download. nil ⇒ media rescues can't complete (return false).
    static var mediaApplier: ((_ sourceURLString: String, _ title: String?, _ assets: [MediaAsset]) async -> Bool)?

    static func install() {
        let engine = URLRescueEngine()

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

        // Price Tracker "no price" → "Ask Apple Intelligence" resolver (Phase 6 UI).
        PriceTrackingViewController.intelligentPriceResolver = { urlString in
            guard let url = URL(string: urlString) else { return nil }
            let request = RescueRequest(url: url, source: .manual, failureKind: .productNoPrice, hint: .product)
            let outcome = await engine.rescue(request)
            guard case .rescued(let result, _) = outcome, case .product(let info, _) = result.outcome else { return nil }
            return PriceTrackingViewController.ResolvedPrice(amount: info.priceAmount, currency: info.priceCurrency)
        }
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
            guard let applier = mediaApplier else { return false }
            return await applier(url.absoluteString, item.title, assets)
        case .unrescuable, .unavailable, .quotaExhausted, .failed:
            return false
        }
    }

    // MARK: - Hint mapping

    static func defaultHint(for surface: AppSurface) -> RescueHint {
        switch surface {
        case .reader: return .article
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
