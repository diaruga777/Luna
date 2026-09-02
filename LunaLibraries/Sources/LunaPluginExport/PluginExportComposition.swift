//
//  PluginExportComposition.swift
//  LunaPluginExport
//

import Foundation
import LunaModels
import LunaPluginKit
import LunaPluginRuntime
import LunaSend
import LunaStorage

/// Where a media save's file is, for whatever installed an answer. The
/// producer reads it when a caller passed none.
public enum PluginExportMediaFiles {
    public static var locator: (any PluginExportMediaFileLocating)?
}

/// The export tier's one root call (`claudedocs/plans/plugin-platform.md` §9).
///
/// `KindWiring+Luna` makes it right after `PluginPlatformComposition.install`,
/// which is the order the tiers need: the destinations and share rows read the
/// runtime the platform just built. The share and action extensions do NOT link
/// this module — an export runs from the app, or not at all.
public enum PluginExportComposition {

    /// Installs the share-row seam, the share presenter, the media-file
    /// locator, and one `ArticleDestination` per destination plugin. Migrates
    /// the Kindle address once.
    ///
    /// Idempotent: a second call replaces the same witnesses and re-reads the
    /// loaded plugins.
    @MainActor
    public static func install(
        mediaFiles: (any PluginExportMediaFileLocating)? = nil,
        recipientPicker: (any PluginMailRecipientPicking)? = nil,
        invoker: (any PluginHookInvoking)? = nil
    ) {
        PluginExportMediaFiles.locator = mediaFiles
        PluginMailRecipients.picker = recipientPicker
        PluginExportStage.shared.presenter = SystemPluginExportSharePresenter()
        PluginExportSeams.rows = PluginExportRowProvider()
        migrateKindleAddress()
        installDestinations(invoker: invoker ?? PluginPlatformServices.invoker)
    }

    /// The capability bridges this module owns (§6.13, §6.14, §6.16).
    ///
    /// They are handed over in every process. Each refuses on its own terms
    /// rather than being absent, so a plugin's declared capability stays
    /// visible and its rejection carries a code it can branch on: outside the
    /// app all three answer `unavailable-here`.
    public static func bridges(
        processKind: PluginProcessKind, scheduler: PluginCallbackScheduling
    ) -> [any PluginCapabilityInstalling] {
        [
            PluginMailBridge(
                processKind: processKind, scheduler: scheduler,
                recipientPicker: PluginMailRecipients.picker),
            PluginNotificationsBridge(processKind: processKind, scheduler: scheduler),
            PluginExportsBridge(processKind: processKind, scheduler: scheduler),
        ]
    }

    /// Registers one destination per loaded plugin that declares itself one,
    /// and retires the Swift destinations they replace.
    static func installDestinations(invoker: (any PluginHookInvoking)?) {
        guard let invoker else {
            ArticleDestinationRegistry.removeAll()
            return
        }
        var destinations: [any ArticleDestination] = []
        var pluginIDs: [String] = []
        for plugin in invoker.loadedPlugins {
            guard let export = plugin.export, export.isDestination else { continue }
            destinations.append(PluginDestination(pluginID: plugin.id, export: export))
            pluginIDs.append(plugin.id)
        }
        ArticleDestinationRegistry.install(
            destinations,
            replacingBuiltInIDs: PluginDestinationLegacyIDs.replacedIDs(
                forLoadedPluginIDs: pluginIDs))
    }

    // MARK: - Kindle migration (§9.5)

    /// Seeds the Kindle plugin's address from `KindleSendSettings` once.
    ///
    /// It also runs when the plugin's own setting is empty, which is what
    /// carries an address typed in Luna Reader — where the Swift destination
    /// still lives — across to the plugin the central app now sends through.
    static func migrateKindleAddress(
        settings: (any PluginSettingsStoring)? = nil,
        legacyAddress: String? = nil
    ) {
        guard let settings = settings ?? PluginPlatformServices.settings else { return }
        let address = (legacyAddress ?? KindleSendSettings.kindleAddress)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.isEmpty else { return }
        let stored = settings.valueJSON(
            pluginID: KindlePlugin.pluginID, key: KindlePlugin.addressSettingKey)
        guard stored == nil || stored == "\"\"" || stored == "null" else { return }
        guard let data = try? JSONSerialization.data(
            withJSONObject: address, options: [.fragmentsAllowed])
        else { return }
        let json = String(decoding: data, as: UTF8.self)
        try? settings.setValueJSON(
            json, pluginID: KindlePlugin.pluginID, key: KindlePlugin.addressSettingKey)
        SharedDiagnosticLog.record(
            "export \(KindlePlugin.pluginID): migrated the Kindle address into the plugin setting",
            category: PluginExportStage.diagnosticsCategory)
    }

}

/// The recipient picker `luna.mail` uses when a plugin names no recipients.
/// Central Luna installs it; every other process leaves it nil, where a
/// recipient-less message is refused rather than sent nowhere.
public enum PluginMailRecipients {
    public static var picker: (any PluginMailRecipientPicking)?
}
