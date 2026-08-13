//
//  LunaShortcuts+SaveOnly.swift
//  Luna
//

import LunaIntents
import AppIntents

/// Surfaces the intents in the Shortcuts app and Spotlight, so they are easy
/// to find when building the Action Button shortcut. This variant omits
/// `ReadArticleIntent`, since read-aloud is article-only. The Downloader and
/// Price Tracker link no article kind, so they compile this list and exclude
/// `LunaShortcuts+ReadAloud.swift`.
struct LunaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ProvideContextIntent(),
            phrases: [
                "Provide context to \(.applicationName)",
            ],
            shortTitle: "Provide Context",
            systemImageName: "questionmark.app"
        )
        AppShortcut(
            intent: SaveIntent(),
            phrases: [
                "Save this screen with \(.applicationName)",
            ],
            shortTitle: "Save",
            systemImageName: "square.and.arrow.down.on.square"
        )
    }
}
