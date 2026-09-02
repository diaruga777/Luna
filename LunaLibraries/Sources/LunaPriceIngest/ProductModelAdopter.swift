//
//  ProductModelAdopter.swift
//  LunaPriceIngest
//

import Foundation
import LunaModels

/// Turns a plugin's `product` Model into a tracker
/// (`claudedocs/plans/plugin-platform.md` §5.3).
///
/// `ProductInfo` lives above LunaModels, so the adopter answers with the Model
/// and the resolved image and `PluginProductInfoBuilder` assembles the value in
/// LunaPluginIngest. The tracker's stores are stamped with the owning plugin
/// when the save is written (`SavesStore.savePriceTracker`), which is what routes
/// a later refresh back through `PluginPriceFetcher`.
public struct ProductModelAdopter: ProductModelAdopting {
    public init() {}

    public func adopt(
        _ model: ProductModel, url: URL, pluginID: String
    ) async -> PluginAdoptedOutcome {
        // A tracker with no amount cannot alert, graph, or compare. The walk
        // continues rather than storing a priceless product.
        guard model.price.amount > 0 else { return .declined }
        return .product(model, imageURL: model.imageURL)
    }
}
