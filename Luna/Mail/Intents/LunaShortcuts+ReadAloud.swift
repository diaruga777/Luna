//
//  LunaShortcuts+ReadAloud.swift
//  Luna
//

import LunaIntents
import AppIntents

/// Reader's automatic shortcuts. Other apps own their own providers; the
/// remaining composable actions are discoverable without using a shortcut slot.
struct LunaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FindSavedItemsIntent(), phrases: ["Find saves in \(.applicationName)"], shortTitle: "Find Saved Items", systemImageName: "magnifyingglass")
        AppShortcut(intent: GetArticleAudioIntent(), phrases: ["Get article audio from \(.applicationName)"], shortTitle: "Get Article Audio", systemImageName: "waveform")
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
