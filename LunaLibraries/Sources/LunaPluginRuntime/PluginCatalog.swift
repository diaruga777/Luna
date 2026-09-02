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

    public init(
        store: PluginStore, bundled: BundledPluginCatalog, runtime: PluginRuntime,
        kv: PluginKVStore = .shared
    ) {
        self.store = store
        self.bundled = bundled
        self.runtime = runtime
        self.kv = kv
    }

    public func listings() -> [PluginListing] {
        installed().map(listing(for:))
    }

    public func listing(pluginID: String) -> PluginListing? {
        installed().first { $0.id == pluginID }.map(listing(for:))
    }

    public func sourceText(pluginID: String) -> String? {
        installed().first { $0.id == pluginID }?.sourceText()
    }

    public func setEnabled(_ enabled: Bool, pluginID: String) throws {
        guard let plugin = installed().first(where: { $0.id == pluginID }) else {
            throw PluginStoreError.notInstalled(id: pluginID)
        }
        store.setEnabled(enabled, pluginID: pluginID, isBundled: plugin.isBundled)
        runtime.reload(pluginID: pluginID)
    }

    /// A bundled plugin can only be switched off. Deleting an imported one takes
    /// its stored rows with it, so a re-import starts clean.
    public func delete(pluginID: String) throws {
        guard let plugin = installed().first(where: { $0.id == pluginID }) else {
            throw PluginStoreError.notInstalled(id: pluginID)
        }
        guard !plugin.isBundled else {
            throw PluginStoreError.bundledCannotBeDeleted(id: pluginID)
        }
        try store.delete(pluginID: pluginID)
        kv.removeAll(pluginID: pluginID)
        runtime.unload(pluginID: pluginID)
        // A bundled plugin of the same id becomes live again, so the runtime is
        // asked to load whatever the id now resolves to.
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
            settings: plugin.manifest.settings)
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
