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
