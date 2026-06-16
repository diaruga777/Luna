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
                "Save this page with \(.applicationName)",
                "Save the current page with \(.applicationName)",
            ],
            shortTitle: "Save Safari Page",
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
        AppShortcut(
            intent: FindBlueskyPostIntent(),
            phrases: [
                "Save a Bluesky post with \(.applicationName)",
            ],
            shortTitle: "Save Bluesky Post",
            systemImageName: "bubble.left.and.bubble.right"
        )
        AppShortcut(
            intent: FindRedditPostIntent(),
            phrases: [
                "Save a Reddit post with \(.applicationName)",
            ],
            shortTitle: "Save Reddit Post",
            systemImageName: "bubble.left.and.text.bubble.right"
        )
    }
}
