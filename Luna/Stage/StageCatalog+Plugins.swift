//
//  StageCatalog+Plugins.swift
//  Luna
//
//  Plugin-kind stages. Only the central Luna app installs these — `install()`
//  gates on `LunaApp.current` at registration time rather than a membership
//  exception (`claudedocs/plans/plugin-platform.md` §14): the three sibling
//  apps do not yet link `LunaPluginUI`, and this file is not excluded from
//  their Sources phase the way the other per-kind catalogs are, so it must
//  not reference plugin UI types at the top level of anything they compile.
//  Once the orchestrator adds a membership exception for this file, the
//  runtime gate below can be dropped.
//

#if DEBUG

import LunaModels
import LunaPluginKit
import LunaPluginUI
import UIKit

enum PluginStageCatalog {

    @MainActor
    static func install() {
        StageRegistry.register(settingsStages + flowStages)
    }

    // MARK: - Settings → Plugins

    @MainActor
    private static var settingsStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "plugins.settings.empty", screen: "Settings → Plugins", variant: "no plugins",
                summary: "Settings → Plugins with nothing installed: the empty row and the Add button.",
                kind: .plugin,
                make: {
                    UINavigationController(
                        rootViewController: PluginsSettingsScreen(
                            catalog: StagePluginCatalog(listings: []),
                            importer: StagePluginImporter(),
                            settingsStore: StagePluginSettingsStore(),
                            invoker: nil))
                }),
            StageDescriptor(
                id: "plugins.settings.list", screen: "Settings → Plugins", variant: "three plugins",
                summary: "Three installed plugins: one enabled, one disabled, and one the runtime "
                    + "stopped after repeated timeouts.",
                kind: .plugin,
                make: {
                    UINavigationController(
                        rootViewController: PluginsSettingsScreen(
                            catalog: StagePluginCatalog(listings: sampleListings()),
                            importer: StagePluginImporter(),
                            settingsStore: StagePluginSettingsStore(),
                            invoker: nil))
                }),
            StageDescriptor(
                id: "plugins.settings.detail", screen: "Plugin detail", variant: "full settings schema",
                summary: "One plugin's settings screen: every field type the schema supports, "
                    + "a stopped status with Re-enable, and Delete for an imported plugin.",
                kind: .plugin,
                make: {
                    let listing = sampleListings()[2]
                    return UINavigationController(
                        rootViewController: PluginDetailScreen(
                            listing: listing,
                            catalog: StagePluginCatalog(listings: [listing]),
                            settingsStore: StagePluginSettingsStore(seeded: listing.summary.id),
                            invoker: nil))
                }),
        ]
    }

    // MARK: - Import and consent

    @MainActor
    private static var flowStages: [StageDescriptor] {
        [
            StageDescriptor(
                id: "plugins.consent", screen: "Plugin consent", variant: "first install",
                summary: "The one screen a plugin is imported through: what it declares, each "
                    + "capability in plain language, and the containment sentence.",
                kind: .plugin,
                make: { PluginConsentViewController(preview: sampleImportPreview()) }),
            StageDescriptor(
                id: "plugins.import.paste", screen: "Paste source", variant: "empty",
                summary: "The 'Paste source' leg of the Add button: a bare text view and Import.",
                kind: .plugin,
                make: { UINavigationController(rootViewController: PluginPasteImportViewController()) }),
        ]
    }

    // MARK: - Fixtures

    private static func sampleListings() -> [PluginListing] {
        [
            PluginListing(
                summary: summary(id: "stage.recipe-saver", name: "Recipe Saver", produces: [.article]),
                description: "Saves recipe pages as clean, readable articles.",
                status: .enabled,
                capabilities: [.fetch, .html, .storage],
                runsInBackground: false,
                settings: []),
            PluginListing(
                summary: summary(id: "stage.gallery-grab", name: "Gallery Grab", produces: [.media]),
                description: "Downloads every image in a gallery post as one save.",
                status: .disabled,
                capabilities: [.fetch, .downloads],
                runsInBackground: false,
                settings: []),
            PluginListing(
                summary: summary(id: "stage.price-watch", name: "Price Watch", produces: [.product]),
                description: "Tracks a product's price on a store this build has no built-in "
                    + "support for.",
                status: .stopped(reason: "Timed out three times in a row"),
                capabilities: [.fetch, .html, .storage, .notifications, .bluetooth],
                runsInBackground: true,
                settings: sampleSettingsFields()),
        ]
    }

    private static func sampleSettingsFields() -> [PluginSettingField] {
        [
            PluginSettingField(
                key: "storeName", type: .text, label: "Store name",
                placeholder: "e.g. Acme Hardware", isRequired: true),
            PluginSettingField(
                key: "accountEmail", type: .email, label: "Account email", isRequired: false),
            PluginSettingField(key: "storeURL", type: .url, label: "Store URL"),
            PluginSettingField(
                key: "apiKey", type: .password, label: "API key", isRequired: true, isSecret: true),
            PluginSettingField(
                key: "pollMinutes", type: .number, label: "Check every (minutes)",
                defaultJSON: "30"),
            PluginSettingField(key: "notifyOnDrop", type: .toggle, label: "Notify on price drop"),
            PluginSettingField(
                key: "currency", type: .choice, label: "Currency",
                options: [
                    PluginSettingOption(id: "usd", label: "USD"),
                    PluginSettingOption(id: "aud", label: "AUD"),
                ]),
            PluginSettingField(key: "reader", type: .pairedDevice, label: "Paired reader"),
            PluginSettingField(key: "resync", type: .action, label: "Resync now"),
            PluginSettingField(
                key: "aboutLimits", type: .info, label: "About this plugin",
                help: "Runs a check on a fixed interval; it cannot watch a page continuously."),
        ]
    }

    private static func summary(
        id: String, name: String, produces: [PluginModelKind]
    ) -> PluginSummary {
        PluginSummary(
            id: id, name: name, version: "1.0.0", priority: 0, matchesAnyHost: false,
            hostPatterns: ["*.example.com"], produces: produces, hooks: [.classify, .ingest],
            export: nil, isBundled: false)
    }

    private static func sampleImportPreview() -> PluginImportPreview {
        PluginImportPreview(
            summary: summary(id: "stage.new-plugin", name: "New Recipe Site", produces: [.article]),
            description: "Reads recipe pages from a site this build does not already support.",
            capabilities: [.fetch, .html, .storage],
            runsInBackground: false,
            addedCapabilities: [.fetch, .html, .storage],
            requiresConsent: true,
            replacesVersion: nil,
            sourceText: "luna.register({ classify: () => null });")
    }
}

// MARK: - Fakes

/// A catalog seeded with fixed listings. Enable/disable and delete mutate the
/// in-memory list so the detail screen's actions have somewhere to land.
private final class StagePluginCatalog: PluginCatalogProviding {
    private var storedListings: [PluginListing]

    init(listings: [PluginListing]) { self.storedListings = listings }

    func listings() -> [PluginListing] { storedListings }

    func listing(pluginID: String) -> PluginListing? {
        storedListings.first { $0.summary.id == pluginID }
    }

    func sourceText(pluginID: String) -> String? {
        "luna.register({\n  classify: (url) => url.host.endsWith('example.com'),\n});\n"
    }

    func setEnabled(_ enabled: Bool, pluginID: String) throws {
        guard let index = storedListings.firstIndex(where: { $0.summary.id == pluginID }) else { return }
        let existing = storedListings[index]
        storedListings[index] = PluginListing(
            summary: existing.summary, description: existing.description,
            status: enabled ? .enabled : .disabled, capabilities: existing.capabilities,
            runsInBackground: existing.runsInBackground, settings: existing.settings)
    }

    func delete(pluginID: String) throws {
        storedListings.removeAll { $0.summary.id == pluginID }
    }
}

/// A settings store seeded with one plugin's values, so the detail stage
/// shows a mix of set and empty fields.
private final class StagePluginSettingsStore: PluginSettingsStoring {
    private var values: [String: [String: String]]

    init(seeded pluginID: String? = nil) {
        guard let pluginID else { values = [:]; return }
        values = [
            pluginID: [
                "storeName": "\"Acme Hardware\"",
                "apiKey": "\"\"",
                "pollMinutes": "30",
                "notifyOnDrop": "true",
                "currency": "\"aud\"",
            ]
        ]
    }

    func valueJSON(pluginID: String, key: String) -> String? { values[pluginID]?[key] }

    func setValueJSON(_ json: String?, pluginID: String, key: String) throws {
        var forPlugin = values[pluginID] ?? [:]
        forPlugin[key] = json
        values[pluginID] = forPlugin
    }

    func allValuesJSON(pluginID: String) -> [String: String] { values[pluginID] ?? [:] }

    func isConfigured(pluginID: String, fields: [PluginSettingField]) -> Bool {
        let all = allValuesJSON(pluginID: pluginID)
        return fields.filter(\.isRequired).allSatisfy { all[$0.key] != nil }
    }
}

/// Accepts any pasted or picked source as a first-install preview, so the Add
/// button's flow is drivable from a stage with nothing behind it for real.
private final class StagePluginImporter: PluginImporting {
    func preview(sourceText: String) throws -> PluginImportPreview {
        PluginImportPreview(
            summary: PluginSummary(
                id: "stage.pasted", name: "Pasted Plugin", version: "1.0.0", priority: 0,
                matchesAnyHost: true, hostPatterns: [], produces: [.article], hooks: [.classify],
                export: nil, isBundled: false),
            description: nil, capabilities: [.fetch], runsInBackground: false,
            addedCapabilities: [.fetch], requiresConsent: true, replacesVersion: nil,
            sourceText: sourceText)
    }

    func install(_ preview: PluginImportPreview, origin: PluginImportOrigin) throws {}
}

#endif
