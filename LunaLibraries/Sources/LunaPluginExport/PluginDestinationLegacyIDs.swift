//
//  PluginDestinationLegacyIDs.swift
//  LunaPluginExport
//

import Foundation
import LunaModels

/// The bundled plugin that ships in place of a Swift `ArticleDestination`, and
/// the destination id it must keep.
///
/// A destination's id is the key of everything the store already holds about
/// it: `send_states`, `datesSent`, the retry counts, and every
/// `SourceSendSettings` per-source toggle. A plugin taking over that
/// destination therefore takes over the ID, not just the delivery — anything
/// else would read as "Luna forgot every article it ever sent".
public enum PluginDestinationLegacyIDs {

    /// Plugin id → the Swift destination id it replaces.
    public static let byPluginID: [String: String] = [
        KindlePlugin.pluginID: ArticleDestinationID.kindle,
        "app.luna.xteink": ArticleDestinationID.xteink,
    ]

    /// The destination id a plugin delivers under: the replaced Swift id when
    /// it has one, else the plugin's own id.
    public static func destinationID(forPluginID pluginID: String) -> String {
        byPluginID[pluginID] ?? pluginID
    }

    /// The Swift destinations the loaded plugins take over.
    public static func replacedIDs(forLoadedPluginIDs ids: [String]) -> Set<String> {
        Set(ids.compactMap { byPluginID[$0] })
    }
}

/// The bundled Kindle plugin's identity (§9.5). Native code needs it for the
/// one-time address migration and for the destination id it keeps.
public enum KindlePlugin {
    public static let pluginID = "app.luna.kindle"
    /// The setting the plugin sends to. The migration seeds it from
    /// `KindleSendSettings`.
    public static let addressSettingKey = "kindleAddress"
}
