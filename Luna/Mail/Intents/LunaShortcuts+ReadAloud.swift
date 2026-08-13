//
//  LunaShortcuts+ReadAloud.swift
//  Luna
//

import LunaIntents
import AppIntents

/// Surfaces the intents in the Shortcuts app and Spotlight, so they are easy
/// to find when building the Action Button shortcut. This variant is for the
/// two apps that link article read-aloud and so compile `ReadArticleIntent`:
/// Luna and LunaReader. The other two apps compile
/// `LunaShortcuts+SaveOnly.swift`, whose list stops at the save pair. Each app
/// excludes the variant it does not use by membership exception.
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
