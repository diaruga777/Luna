//
//  PluginPriceFetcher.swift
//  LunaPluginIngest
//

import Foundation
import LunaModels
import LunaPluginKit

/// Refreshes a plugin-owned tracker store by re-running its plugin
/// (`claudedocs/plans/plugin-platform.md` §5.3).
///
/// It calls the SAME `ingest` hook a save calls, with `reason: "refresh"`, and
/// reads only `price` off the returned Model. Everything else the plugin
/// returns is ignored: a refresh must not rename the product or rewrite the
/// seller list the user is tracking.
public final class PluginPriceFetcher: PluginPriceFetching {

    private let invoker: any PluginHookInvoking
    private let processKind: PluginProcessKind

    public init(invoker: any PluginHookInvoking, processKind: PluginProcessKind) {
        self.invoker = invoker
        self.processKind = processKind
    }

    public func price(forStoreURL url: URL, pluginID: String) async -> PluginStorePrice? {
        // A tracker stamps its plugin onto every store it owns, alternative
        // sellers included, and those sit on hosts the plugin never claimed.
        // Asking it for a price there either wastes an invocation or lets a lax
        // plugin report the canonical product's price into a seller's history.
        guard let host = url.host?.lowercased(), !host.isEmpty,
              let plugin = invoker.matchedPlugins(forHost: host)
                  .first(where: { $0.id == pluginID }),
              plugin.produces.contains(.product)
        else { return nil }

        let answer = await invoker.invoke(
            .ingest, pluginID: pluginID,
            argument: PluginIngestHookInput(
                url: url.absoluteString,
                claim: PluginIngestClaim(kind: .product, itemID: nil),
                page: nil, reason: .refresh, context: processKind),
            timeout: PluginIngestStage.ingestTimeout, decode: PluginIngestAnswer.self)

        guard case let .success(.model(model)) = answer,
              case let .product(product) = model
        else { return nil }
        guard product.price.amount > 0 else { return nil }
        return PluginStorePrice(
            amount: product.price.amount, currency: product.price.currency.uppercased())
    }
}
