//
//  PluginPlatformFallbacks.swift
//  LunaPluginUI
//

import Foundation
import LunaPluginKit

/// Thrown by a fallback witness when the real plugin platform has not been
/// installed in this process yet.
public struct PluginPlatformUnavailable: Error, Equatable {
    public init() {}
}

/// A catalog with nothing installed. Settings → Plugins uses this in place of
/// `PluginPlatformServices.catalog` so the screen degrades to an empty list
/// rather than crashing in a process where `PluginPlatformComposition.install()`
/// has not run yet.
public final class NullPluginCatalog: PluginCatalogProviding {
    public init() {}
    public func listings() -> [PluginListing] { [] }
    public func listing(pluginID: String) -> PluginListing? { nil }
    public func sourceText(pluginID: String) -> String? { nil }
    public func setEnabled(_ enabled: Bool, pluginID: String) throws { throw PluginPlatformUnavailable() }
    public func delete(pluginID: String) throws { throw PluginPlatformUnavailable() }
}

/// A settings store with nothing recorded, for the same reason.
public final class NullPluginSettingsStore: PluginSettingsStoring {
    public init() {}
    public func valueJSON(pluginID: String, key: String) -> String? { nil }
    public func setValueJSON(_ json: String?, pluginID: String, key: String) throws {
        throw PluginPlatformUnavailable()
    }
    public func allValuesJSON(pluginID: String) -> [String: String] { [:] }
    public func isConfigured(pluginID: String, fields: [PluginSettingField]) -> Bool {
        fields.filter(\.isRequired).isEmpty
    }
}
