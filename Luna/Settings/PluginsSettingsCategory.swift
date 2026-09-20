//
//  PluginsSettingsCategory.swift
//  Luna
//
//  The Settings → Plugins entry (plugin-platform.md §11.2). Central Luna
//  only — `KindWiring+Luna.settingsCategories()` is the one caller.
//

import LunaDesignSystem
import LunaModels
import LunaPluginKit
import LunaPluginUI

enum PluginsSettingsCategory {

    static func make() -> SettingsCategory {
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
                // The category's factory runs when Settings pushes the screen,
                // which is on the main thread; the launcher is main-actor bound.
                launcher: MainActor.assumeIsolated { LLMLauncher.shared })
        }
    }
}
