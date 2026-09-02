//
//  PluginPlatformComposition.swift
//  LunaPluginIngest
//

import Foundation
import LunaIngest
import LunaModels
import LunaPluginKit

/// THE single root call of the plugin platform
/// (`claudedocs/plans/plugin-platform.md` §2.3).
///
/// Exactly three composition roots make it — `KindWiring+Luna`,
/// `ShareEntry+Luna`, `ActionEntry+Luna` — after their kind packs, because the
/// walk refuses a Model whose kind has no adopter and the packs install those.
/// `KindCompositionRootTests` pins both halves: those three roots call this, and
/// nothing else writes `PluginPlatformServices` or `IngestPipeline.pluginStage`.
///
/// It is a no-op until the runtime installs `PluginPlatformServices.invoker`, so
/// a process that loads no plugins carries the call harmlessly.
public enum PluginPlatformComposition {

    /// Installs the ingest stage and the media seams for `processKind`.
    /// Idempotent: calling it twice replaces the same witnesses.
    public static func install(
        processKind: PluginProcessKind, swiftMediaResolver: (any SocialMediaResolving)? = nil
    ) {
        guard let invoker = PluginPlatformServices.invoker else {
            IngestPipeline.pluginStage = nil
            return
        }
        IngestPipeline.pluginStage = PluginIngestStage(
            invoker: invoker, processKind: processKind)

        let resolver = PluginMediaResolver(
            invoker: invoker, processKind: processKind, fallback: swiftMediaResolver)
        PluginMediaSeams.resolver = resolver
        PluginMediaSeams.reresolver = resolver

        PluginPriceSeams.fetcher = PluginPriceFetcher(
            invoker: invoker, processKind: processKind)
    }
}
