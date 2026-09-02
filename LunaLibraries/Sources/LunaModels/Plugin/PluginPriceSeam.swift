//
//  PluginPriceSeam.swift
//  LunaModels
//

import Foundation

/// Refreshes one plugin-owned tracker store by re-running its plugin's `ingest`
/// hook with `reason: "refresh"` and reading the Model's `price`
/// (`claudedocs/plans/plugin-platform.md` §5.3).
///
/// `PriceFetching` (LunaPriceUI) takes a URL and nothing else, so it cannot
/// route by owner. This seam carries the plugin id the store was stamped with,
/// which is the whole point of `tracker_stores.plugin_id`.
public protocol PluginPriceFetching {
    /// The store's current price, or nil when the plugin is gone, declined, or
    /// returned no product. The refresher then falls back to the Swift fetcher.
    func price(forStoreURL url: URL, pluginID: String) async -> PluginStorePrice?
}

/// One refreshed price. Kept in LunaModels because `ProductPrice` lives above
/// it, in LunaHTMLClassification.
public struct PluginStorePrice: Equatable, Sendable {
    public let amount: Decimal
    public let currency: String

    public init(amount: Decimal, currency: String) {
        self.amount = amount
        self.currency = currency
    }
}

/// The price seam a plugin platform fills, held at the bottom of the stack for
/// the same reason `PluginMediaSeams` is: LunaPluginIngest cannot import
/// LunaPriceUI. `PluginPlatformComposition.install()` is the only writer.
public enum PluginPriceSeams {
    public static var fetcher: (any PluginPriceFetching)?
}
