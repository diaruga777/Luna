//
//  PluginMediaResolver.swift
//  LunaPluginIngest
//

import Foundation
import LunaModels
import LunaPluginKit

/// The plugin walk as an asset resolver (`claudedocs/plans/plugin-platform.md`
/// §7.6).
///
/// Central Luna's ingest produces `Outcome.video`/`.social` from a plugin's
/// `media` Model exactly as the Swift path does, so the download engine still
/// asks a `SocialMediaResolving` for the assets. This is what it asks: the same
/// classify + ingest walk, reading the Model's assets through the media adopter.
///
/// It also re-resolves an expired job, with `reason: "reresolve"`, which is the
/// same walk under a different reason.
public final class PluginMediaResolver: SocialMediaResolving, MediaReresolving {

    private let invoker: any PluginHookInvoking
    private let processKind: PluginProcessKind

    public init(invoker: any PluginHookInvoking, processKind: PluginProcessKind) {
        self.invoker = invoker
        self.processKind = processKind
    }

    // MARK: - SocialMediaResolving

    /// The plugins resolve every platform central Luna downloads from, so a URL
    /// none of them claims has no assets. The Swift resolvers stay in
    /// LunaMediaResolve for the Downloader app and the sibling Safari appexes.
    public func resolveAssets(for url: URL) async -> [MediaAsset] {
        await walk(url: url, reason: .save, saveID: nil) ?? []
    }

    // MARK: - MediaReresolving

    public func reresolve(
        sourceURL: URL, pluginID: String, saveID: String
    ) async -> [MediaAsset]? {
        await walk(url: sourceURL, reason: .reresolve, saveID: saveID, onlyPluginID: pluginID)
    }

    // MARK: - The walk

    /// Runs classify + ingest over the matched plugins and returns the first
    /// `media` Model's assets. Nil means no plugin produced any.
    private func walk(
        url: URL, reason: PluginIngestReason, saveID: String?, onlyPluginID: String? = nil
    ) async -> [MediaAsset]? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        guard let adopter = PluginModelAdopters.media else { return nil }
        var matched = invoker.matchedPlugins(forHost: host)
        if let onlyPluginID { matched = matched.filter { $0.id == onlyPluginID } }

        for plugin in matched where plugin.produces.contains(.media) {
            guard plugin.hooks.contains(.classify), plugin.hooks.contains(.ingest) else { continue }
            let classified = await invoker.invoke(
                .classify, pluginID: plugin.id,
                argument: PluginClassifyInput(
                    url: url.absoluteString, page: nil, context: processKind),
                timeout: PluginIngestStage.classifyTimeout, decode: PluginClassifyVerdict.self)
            guard case let .success(.claimed(kind, itemID, _)) = classified, kind == .media else {
                continue
            }

            let ingested = await invoker.invoke(
                .ingest, pluginID: plugin.id,
                argument: PluginIngestHookInput(
                    url: url.absoluteString,
                    claim: PluginIngestClaim(kind: .media, itemID: itemID),
                    page: nil, reason: reason, context: processKind, saveID: saveID),
                timeout: PluginIngestStage.ingestTimeout, decode: PluginIngestAnswer.self)
            guard case let .success(.model(model)) = ingested,
                  case let .media(media) = model.resolvingRelativeURLs(against: url)
            else { continue }

            if case let .media(assets, _, _, _, _) = await adopter.adopt(
                media, url: url, pluginID: plugin.id), !assets.isEmpty {
                return assets
            }
        }
        return nil
    }
}
