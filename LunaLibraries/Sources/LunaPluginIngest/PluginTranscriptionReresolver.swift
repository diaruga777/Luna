//
//  PluginTranscriptionReresolver.swift
//  LunaPluginIngest
//

import Foundation
import LunaIngest
import LunaModels
import LunaPluginKit

/// The plugin walk as a transcription re-resolver
/// (`claudedocs/plans/transcription-plugins.md` §5.3).
///
/// A recording URL a plugin returned is short-lived. When the runner finds it
/// expired or refused, this re-runs the SAME plugin's `classify` and `ingest`
/// with reason `reresolve`, the way `PluginMediaResolver.reresolve` does for a
/// download, and reads the answer through the article adopter. The plugin may
/// now have the text itself (captions appeared), which the runner persists
/// without a download.
public final class PluginTranscriptionReresolver: TranscriptionReresolving {

    private let invoker: any PluginHookInvoking
    private let processKind: PluginProcessKind

    public init(invoker: any PluginHookInvoking, processKind: PluginProcessKind) {
        self.invoker = invoker
        self.processKind = processKind
    }

    public func reresolve(
        sourceURL: URL, pluginID: String, saveID: UUID
    ) async -> TranscriptionReresolution? {
        guard let host = sourceURL.host?.lowercased(), !host.isEmpty else { return nil }
        guard let adopter = PluginModelAdopters.article else { return nil }
        guard let plugin = invoker.matchedPlugins(forHost: host).first(where: { $0.id == pluginID }),
              plugin.produces.contains(.article),
              plugin.hooks.contains(.classify), plugin.hooks.contains(.ingest)
        else { return nil }

        let classified = await invoker.invoke(
            .classify, pluginID: plugin.id,
            argument: PluginClassifyInput(
                url: sourceURL.absoluteString, page: nil, context: processKind,
                intent: IngestIntent.transcribe.rawValue),
            timeout: PluginIngestStage.classifyTimeout, decode: PluginClassifyVerdict.self)
        guard case let .success(.claimed(kind, itemID, _)) = classified, kind == .article else {
            return nil
        }

        let ingested = await invoker.invoke(
            .ingest, pluginID: plugin.id,
            argument: PluginIngestHookInput(
                url: sourceURL.absoluteString,
                claim: PluginIngestClaim(kind: .article, itemID: itemID),
                page: nil, reason: .reresolve, context: processKind,
                saveID: saveID.uuidString, intent: IngestIntent.transcribe.rawValue),
            timeout: PluginIngestStage.ingestTimeout, decode: PluginIngestAnswer.self)
        guard case let .success(.model(model)) = ingested,
              case let .article(article) = model.resolvingRelativeURLs(against: sourceURL)
        else { return nil }

        switch await adopter.adopt(article, url: sourceURL, page: .none, pluginID: plugin.id) {
        case let .transcription(request):
            return .request(request)
        case let .article(content, _):
            return .article(content)
        case .media, .product, .declined, .failed:
            return nil
        }
    }
}
