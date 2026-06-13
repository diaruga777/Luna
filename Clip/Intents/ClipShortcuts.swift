//
//  ClipShortcuts.swift
//  Clip
//

import AppIntents

/// Surfaces the intents in the Shortcuts app and Spotlight so they're easy to
/// find when building the Action Button shortcut.
struct ClipShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ClipSafariPageIntent(),
            phrases: [
                "Clip this page with \(.applicationName)",
                "Save this page with \(.applicationName)",
            ],
            shortTitle: "Clip Safari Page",
            systemImageName: "safari"
        )
        AppShortcut(
            intent: SaveLinkIntent(),
            phrases: [
                "Save link with \(.applicationName)",
            ],
            shortTitle: "Save Link",
            systemImageName: "link.badge.plus"
        )
        AppShortcut(
            intent: FindYouTubeVideoIntent(),
            phrases: [
                "Save a YouTube video with \(.applicationName)",
            ],
            shortTitle: "Save YouTube Video",
            systemImageName: "play.rectangle"
        )
    }
}
