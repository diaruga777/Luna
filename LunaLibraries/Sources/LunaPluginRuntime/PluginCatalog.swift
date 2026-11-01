//
//  PluginCatalog.swift
//  LunaPluginRuntime
//

import Foundation
import LunaPluginKit

/// What Settings → Plugins reads: every plugin on the device, whether the
/// runtime is calling it, and why not when it is not.
///
/// It reads the STORE rather than the runtime's loaded list, so a plugin that
/// is switched off or failed to load still has a row. The runtime supplies the
/// status.
public final class PluginCatalog: PluginCatalogProviding {

    private let store: PluginStore
    private let bundled: BundledPluginCatalog
    private let runtime: PluginRuntime
    private let kv: PluginKVStore
    private let includeUnrevealedBundledPlugins: Bool
    private let secrets: PluginSecretsStore

    public init(
        store: PluginStore, bundled: BundledPluginCatalog, runtime: PluginRuntime,
        kv: PluginKVStore = .shared, secrets: PluginSecretsStore = .shared,
        includeUnrevealedBundledPlugins: Bool = BundledPluginCatalog.includesUnrevealedPlugins
    ) {
        self.includeUnrevealedBundledPlugins = includeUnrevealedBundledPlugins
        self.store = store
        self.bundled = bundled
        self.runtime = runtime
        self.kv = kv
        self.secrets = secrets
        // Migrate imports retained from earlier app versions. Later installs
        // record this only after activation succeeds, so a staged/rejected
        // candidate cannot reveal defaults while the UI reads the catalog.
        for plugin in store.installedPlugins() {
            try? bundled.revealIfCompeting(with: plugin.manifest)
            if store.bundledPluginsRevealed { break }
        }
    }

    public func listings() -> [PluginListing] {
        installed().map(listing(for:))
    }

    public func managementListings() -> [PluginListing] {
        manageable().map(listing(for:))
    }

    public func canManage(pluginID: String) -> Bool {
        manageable().contains { $0.id == pluginID }
    }

    public func revealBundledPlugins() throws {
        try bundled.revealForDiagnostics()
    }

    private func manageable() -> [InstalledPlugin] {
        let imported = store.installedPlugins()
        return (imported + bundled.managementPlugins(
            shadowedBy: imported, includeUnrevealed: includeUnrevealedBundledPlugins))
            .sorted { $0.id < $1.id }
    }

    public func listing(pluginID: String) -> PluginListing? {
        // A single destination's readiness check must not enumerate and parse
        // every imported plugin. Imported versions still shadow bundled ones.
        (store.plugin(id: pluginID) ?? bundled.plugin(id: pluginID)).map(listing(for:))
    }

    public func sourceText(pluginID: String) -> String? {
        guard canManage(pluginID: pluginID) else { return nil }
        return (store.plugin(id: pluginID) ?? bundled.plugin(id: pluginID))?.sourceText()
    }

    public func setEnabled(_ enabled: Bool, pluginID: String) throws {
        guard canManage(pluginID: pluginID),
              let plugin = installed().first(where: { $0.id == pluginID }) else {
            throw PluginStoreError.notInstalled(id: pluginID)
        }
        try store.setEnabledChecked(enabled, pluginID: pluginID, isBundled: plugin.isBundled)
        runtime.reload(pluginID: pluginID)
    }

    public func setAutoShowSafariPlayer(_ enabled: Bool, pluginID: String) throws {
        guard canManage(pluginID: pluginID),
              let plugin = installed().first(where: { $0.id == pluginID }) else {
            throw PluginStoreError.notInstalled(id: pluginID)
        }
        guard plugin.manifest.produces.contains(.media) else { return }
        try store.setAutoShowSafariPlayerChecked(enabled, pluginID: pluginID, isBundled: plugin.isBundled)
    }

    /// A bundled plugin can only be switched off. Deleting an imported one takes
    /// its stored rows with it, so a re-import starts clean.
    public func delete(pluginID: String) throws {
        guard canManage(pluginID: pluginID),
              let plugin = installed().first(where: { $0.id == pluginID }) else {
            throw PluginStoreError.notInstalled(id: pluginID)
        }
        guard !plugin.isBundled else {
            throw PluginStoreError.bundledCannotBeDeleted(id: pluginID)
        }
        try store.delete(pluginID: pluginID)
        try kv.removeAllChecked(pluginID: pluginID)
        secrets.removeAll(pluginID: pluginID)
        // `reload` unloads first, and a bundled plugin of the same id becomes
        // live again, so this loads whatever the id now resolves to.
        runtime.reload(pluginID: pluginID)
    }

    // MARK: - Internals

    private func installed() -> [InstalledPlugin] {
        let imported = store.installedPlugins()
        return (imported + bundled.plugins(shadowedBy: imported)).sorted { $0.id < $1.id }
    }

    private func listing(for plugin: InstalledPlugin) -> PluginListing {
        let loaded = runtime.loaded.first { $0.id == plugin.id }
        return PluginListing(
            summary: loaded?.summary
                ?? plugin.manifest.summary(hooks: [], isBundled: plugin.isBundled),
            description: plugin.manifest.description,
            status: status(for: plugin),
            capabilities: plugin.manifest.capabilities,
            runsInBackground: plugin.manifest.runsInBackground,
            settings: plugin.manifest.settings,
            autoShowSafariPlayer: plugin.state.autoShowSafariPlayer)
    }

    private func status(for plugin: InstalledPlugin) -> PluginStatus {
        switch runtime.disabled[plugin.id] {
        case .stopped: return .stopped(reason: "stopped")
        case .loadFailed(let message): return .loadFailed(message: message)
        case .userDisabled: return .disabled
        case nil:
            return runtime.loaded.contains { $0.id == plugin.id } ? .enabled : .disabled
        }
    }
}
