//
//  PluginsSettingsCategory.swift
//  Luna
//
//  The Settings → Plugins entry (plugin-platform.md §11.2). Central Luna
//  only — `KindWiring+Luna.settingsCategories()` is the one caller.
//

import LunaModels
import LunaPluginKit
import LunaPluginUI
import LunaStorage

enum PluginsSettingsCategory {

    /// `launcher` is how this app opens a chat model; the Create button is
    /// absent without one.
    static func make(launcher: (any LLMLaunching)? = nil) -> SettingsCategory {
        SettingsCategory(
            title: L10n.string("Common_plugins"),
            symbol: "puzzlepiece.extension",
            detail: {
                let count = (PluginPlatformServices.catalog ?? NullPluginCatalog()).listings().count
                return count == 0 ? nil : L10n.string("Plugins_countDetail", count)
            }
        ) {
            PluginsSettingsScreen(
                catalog: PluginPlatformServices.catalog ?? NullPluginCatalog(),
                importer: PluginPlatformServices.importer,
                settingsStore: PluginPlatformServices.settings ?? NullPluginSettingsStore(),
                invoker: PluginPlatformServices.invoker,
                launcher: launcher)
        }
    }
}
