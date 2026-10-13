//
//  PluginPlatformComposition.swift
//  LunaPluginIngest
//

import Foundation
import LunaIngest
import LunaModels
import LunaPluginKit
import LunaPluginRuntime
import LunaStorage

/// THE single root call of the plugin platform
/// (`claudedocs/plans/plugin-platform.md` §2.3).
///
/// Exactly three composition roots make it — `KindWiring+Luna`,
/// `ShareEntry+Luna`, `ActionEntry+Luna` — after their kind packs, because the
/// walk refuses a Model whose kind has no adopter and the packs install those.
/// `KindCompositionRootTests` pins both halves: those three roots call this, and
/// nothing else writes `PluginPlatformServices` or `IngestPipeline.pluginStage`.
///
/// It builds the whole platform for this process: the store, the bundled
/// catalog, the capability registry with the runtime's own bridges plus whatever
/// a higher tier hands over, the runtime itself, the Settings catalog, the
/// importer and the settings store. Every `PluginPlatformServices` witness is
/// set before the stage and the media/price seams are wired, so the stage a
/// caller finds installed is one a loaded runtime can serve.
public enum PluginPlatformComposition {

    /// The runtime this process is holding. It is kept so a second `install`
    /// replaces one platform with another rather than leaving two runtimes
    /// sharing the store.
    private static var runtime: PluginRuntime?

    /// The store this process is holding, and the change token it last loaded.
    private static var store: PluginStore?
    private static var loadedChangeToken: String?

    /// Builds the platform and installs the ingest stage and the media and price
    /// seams for `processKind`.
    ///
    /// `bundledPluginsBundle` is the `LunaBundledPlugins` resource bundle — it is
    /// injected because LunaPluginIngest sits below that target in the link
    /// graph. `additionalBridges` are the capability bridges higher tiers own
    /// (browser, ui, settings); the runtime's own six are registered here.
    ///
    /// Idempotent: calling it twice replaces the same witnesses.
    @discardableResult
    @MainActor
    public static func install(
        processKind: PluginProcessKind,
        bundledPluginsBundle: Bundle?,
        additionalBridges: (PluginCallbackScheduling) -> [any PluginCapabilityInstalling] = { _ in [] },
        store: PluginStore = .shared,
        keyValueStore: PluginKVStore = .shared
    ) -> [PluginLoadReport] {
        let bundled = BundledPluginCatalog(bundle: bundledPluginsBundle, store: store)
        let capabilities = PluginCapabilityRegistry()
        // One scratch store serves every plugin, keyed by (plugin, generation):
        // a generation is open while anything of that plugin is in flight, and
        // its directory is reaped when the last of those calls ends.
        let scratch = PluginScratchStore(
            rootURL: store.scratchRootURL, isAvailable: store.storageAvailable)
        let runtime = PluginRuntime(
            store: store, bundled: bundled, capabilities: capabilities,
            processContext: PluginProcessContext(kind: processKind), scratch: scratch)
        Self.runtime = runtime
        Self.store = store

        let fetcher = PluginFetchService()
        fetcher.idle = runtime
        fetcher.fileWriter = scratch
        capabilities.register(PluginFetchBridge(
            fetcher: fetcher, scheduler: runtime, files: scratch))
        capabilities.register(PluginHTMLBridge(scheduler: runtime))
        capabilities.register(PluginStorageBridge(store: keyValueStore, scheduler: runtime))
        capabilities.register(PluginSecretsBridge(
            scheduler: runtime, processKind: processKind))
        capabilities.register(PluginFilesBridge(scratch: scratch, scheduler: runtime))
        capabilities.register(PluginCryptoBridge(scheduler: runtime))
        capabilities.register(PluginDownloadsBridge(scheduler: runtime))
        for bridge in additionalBridges(runtime) { capabilities.register(bridge) }

        PluginPlatformServices.invoker = runtime
        PluginPlatformServices.catalog = PluginCatalog(
            store: store, bundled: bundled, runtime: runtime, kv: keyValueStore)
        PluginPlatformServices.importer = PluginImporter(
            store: store, bundled: bundled, runtime: runtime)
        let settings = PluginSettingsStore(values: keyValueStore) { id in
            store.plugin(id: id)?.manifest.settings
                ?? bundled.plugin(id: id)?.manifest.settings ?? []
        }
        // Migrate legacy secret fields before any plugin can read ordinary storage.
        let imported = store.installedPlugins()
        for plugin in imported + bundled.plugins(shadowedBy: imported) {
            _ = settings.allValuesJSON(pluginID: plugin.id)
        }
        PluginPlatformServices.settings = settings
        PluginPlatformServices.scratch = scratch

        let reports = runtime.loadAll()
        Self.loadedChangeToken = store.changeToken

        IngestPipeline.pluginStage = PluginIngestStage(
            invoker: runtime, processKind: processKind)
        let resolver = PluginMediaResolver(invoker: runtime, processKind: processKind)
        PluginMediaSeams.resolver = resolver
        PluginMediaSeams.reresolver = resolver
        PluginTranscriptionSeams.reresolver = PluginTranscriptionReresolver(
            invoker: runtime, processKind: processKind)
        PluginPriceSeams.fetcher = PluginPriceFetcher(
            invoker: runtime, processKind: processKind)
        PluginBrowserDeferral.witness = StoredPluginBrowserDeferral()
        return reports
    }

    /// Reloads this process's runtime when the App-Group store has changed
    /// since it last loaded. A share or action extension can install a plugin
    /// while the app is suspended, and the app's runtime would otherwise keep
    /// serving the set it read at launch.
    @MainActor
    public static func reloadIfStoreChanged() {
        guard let runtime, let store else { return }
        let token = store.changeToken
        guard token != loadedChangeToken else { return }
        loadedChangeToken = token
        runtime.reloadAll()
    }
}
