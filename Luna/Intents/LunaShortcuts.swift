//
//  LunaShortcuts.swift
//  Luna
//

import LunaIntents
import AppIntents

/// Surfaces the intents in the Shortcuts app and Spotlight so they're easy to
/// find when building the Action Button shortcut.
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
        AppShortcut(
            intent: ReadArticleIntent(),
            phrases: [
                "Read my \(.applicationName) article",
                "Read my latest \(.applicationName) article",
                "Read my \(.applicationName) article about \(\.$article)",
                "Read my \(.applicationName) article from \(\.$article)",
                "Play my \(.applicationName) article about \(\.$article)",
                "Play my \(.applicationName) article from \(\.$article)",
                "Play my latest \(.applicationName) article",
            ],
            shortTitle: "Read Article",
            systemImageName: "speaker.wave.2"
        )
    }
}
