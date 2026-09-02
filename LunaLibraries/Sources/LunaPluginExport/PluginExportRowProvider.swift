//
//  PluginExportRowProvider.swift
//  LunaPluginExport
//

import Foundation
import LunaModels
import LunaPluginKit
import LunaStorage

/// The reserved settings keys Luna itself reads. A schema may not declare one
/// (§11.1 keeps the leading underscore), and `luna.settings.set` accepts them
/// anyway so a plugin can report state Luna renders.
public enum PluginReservedSettingKeys {
    /// A destination plugin's own liveness, for the share row's status dot:
    /// `"live"` lights it, anything else leaves it dim (§9.3).
    public static let status = "_status"
    public static let liveValue = "live"
}

/// One share row per loaded export plugin that handles this save's kind and is
/// configured (`claudedocs/plans/plugin-platform.md` §9.3).
///
/// The three share menus that show these rows compile into apps that link no
/// plugin module, so they read `PluginExportSeams.rows` and get VALUES. This is
/// the witness behind that seam.
public final class PluginExportRowProvider: PluginExportRowProviding {

    private let invoker: (any PluginHookInvoking)?
    private let stage: PluginExportStage?

    /// The shipped provider reads the installed platform and the shared stage.
    public init(invoker: (any PluginHookInvoking)? = nil, stage: PluginExportStage? = nil) {
        self.invoker = invoker
        self.stage = stage
    }

    private var activeInvoker: (any PluginHookInvoking)? {
        invoker ?? PluginPlatformServices.invoker
    }

    public func exportRows(
        forSaveID saveID: UUID, kind: PluginModelKind
    ) -> [PluginExportRowSpec] {
        guard let invoker = activeInvoker else { return [] }
        return invoker.loadedPlugins.compactMap { plugin in
            guard let export = plugin.export, export.kinds.contains(kind) else { return nil }
            guard PluginExportConfiguration.isConfigured(pluginID: plugin.id, export: export)
            else { return nil }
            return PluginExportRowSpec(
                pluginID: plugin.id,
                title: export.title,
                symbolName: export.symbol ?? Self.defaultSymbol(export),
                isLive: Self.isLive(pluginID: plugin.id, export: export))
        }
    }

    @MainActor
    public func runExport(pluginID: String, saveID: UUID) {
        let stage = self.stage ?? PluginExportStage.shared
        Task { @MainActor in
            await stage.run(pluginID: pluginID, saveID: saveID, auto: false)
        }
    }

    /// A destination row looks like the two Swift ereader rows; every other
    /// export row is a share.
    static func defaultSymbol(_ export: PluginExportSummary) -> String {
        export.isDestination ? "book.closed" : "square.and.arrow.up"
    }

    /// Only a destination draws a dot: a share row has no connection to report.
    static func isLive(pluginID: String, export: PluginExportSummary) -> Bool? {
        guard export.isDestination else { return nil }
        let json = PluginPlatformServices.settings?
            .valueJSON(pluginID: pluginID, key: PluginReservedSettingKeys.status)
        return json == "\"\(PluginReservedSettingKeys.liveValue)\""
    }
}

/// Whether an export plugin can be offered at all: it must still be enabled,
/// its required settings filled in, and — when it sends mail — an account
/// connected.
public enum PluginExportConfiguration {

    public static func isConfigured(pluginID: String, export: PluginExportSummary) -> Bool {
        guard let listing = PluginPlatformServices.catalog?.listing(pluginID: pluginID),
              listing.status == .enabled
        else { return false }
        guard let settings = PluginPlatformServices.settings else { return false }
        guard settings.isConfigured(pluginID: pluginID, fields: listing.settings) else {
            return false
        }
        for key in export.requiresSettings {
            guard let json = settings.valueJSON(pluginID: pluginID, key: key),
                  !json.isEmpty, json != "null", json != "\"\"", json != "false"
            else { return false }
        }
        // A plugin that declares `mail` sends through the connected account,
        // so it is no more configured than that account is — the same rule
        // `KindleSendSettings.isConfigured` holds.
        guard listing.capabilities.contains(.mail) else { return true }
        return PluginExportMailAccount.isReady
    }
}
