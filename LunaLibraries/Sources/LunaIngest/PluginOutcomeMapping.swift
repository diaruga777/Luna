//
//  PluginOutcomeMapping.swift
//  LunaIngest
//

import Foundation
import LunaHTMLClassification
import LunaModels

/// The one mapping from a kind module's `PluginAdoptedOutcome` to the pipeline's
/// `Outcome` (`claudedocs/plugins.md` §6).
///
/// Two callers reach it from different tiers — `PluginIngestStage` (the
/// in-process walk) and `PluginModelDrain` (the Safari hand-off) — and both must
/// answer the same thing for the same adoption. It lives here because LunaIngest
/// owns `Outcome` and both callers already link it.
///
public enum PluginOutcomeMapping {

    /// The outcome to save, or nil when the adopter kept nothing.
    ///
    /// `.declined` and `.failed` both answer nil, and both callers then fall
    /// through to the Swift classifier. An adopter that could not read a
    /// plugin's Model must never fail a save Swift could still make.
    public static func outcome(
        from adopted: PluginAdoptedOutcome,
        productInfo: (ProductModel, URL?) -> ProductInfo = PluginProductInfoBuilder.make(from:imageURL:)
    ) -> Outcome? {
        switch adopted {
        case .declined, .failed:
            return nil
        case let .media(assets, platform, itemID, _, _):
            // The same two outcomes the Swift platform path produces, so the
            // media card, the Live Activity and the auto-download policy see no
            // difference between a plugin save and a native one.
            let hasTimeline = assets.contains { $0.kind == .video || $0.kind == .audio }
            return hasTimeline
                ? .video(platform ?? .web, itemID: itemID)
                : .social(platform ?? .web, itemID: itemID)
        case let .article(content, sourceHTML):
            return .article(content, html: sourceHTML ?? "")
        case let .transcription(request):
            return .transcription(request)
        case let .product(model, imageURL):
            return .product(productInfo(model, imageURL), html: "")
        }
    }
}
