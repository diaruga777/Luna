//
//  AppNamePlatform.swift
//  Clip
//

import Foundation

/// Maps the current-app name (from Shortcuts' "Get Current App") to a content
/// platform, and supplies the screen-extraction prompt per platform.
/// Shared by the generic save intent and the screen-prompt intent.
enum AppNamePlatform {

    /// The platform for an app name, or nil (Safari / unknown → plain URL).
    static func platform(forAppName app: String) -> ContentPlatform? {
        let name = app.lowercased()
        if name.contains("youtube") { return .youtube }
        if name.contains("bluesky") { return .bluesky }
        if name.contains("tiktok") { return .tiktok }
        if name.contains("reddit") { return .reddit }
        if name.contains("instagram") { return .instagram }
        if name.contains("facebook") { return .facebook }
        if name.contains("podcast") { return .podcast }
        if name.contains("spotify") || name.contains("music") { return .music }
        if name == "x" || name.contains("twitter") { return .x }
        return nil
    }

    /// The screen-extraction prompt for pulling identifying metadata from a
    /// screenshot of `app`, or nil when none applies (Safari, unknown apps). The
    /// caller appends the screenshot and runs prompt+image through an image model.
    static func screenPrompt(forAppName app: String) -> String? {
        guard let platform = platform(forAppName: app) else { return nil }
        switch platform {
        case .youtube:
            return "Return the YouTube video on screen as \"channel_name:video_title\" or \"none\":"
        case .music:
            return "Return the song on screen as \"artist:title\" or \"none\":"
        case .podcast:
            return "Return the podcast on screen as \"show:episode_title\" or \"none\":"
        case .bluesky:
            return "Return a short search phrase (author plus a few distinctive words) for the Bluesky post on screen, or \"none\":"
        case .reddit:
            return "Return a short search phrase (subreddit plus the title) for the Reddit post on screen, or \"none\":"
        case .x:
            return "Return the X post on screen as \"author:post_text\" or \"none\":"
        case .tiktok:
            return "Return the TikTok on screen as \"creator:caption\" or \"none\":"
        case .instagram:
            return "Return the Instagram post on screen as \"account:caption\" or \"none\":"
        case .facebook:
            return "Return the Facebook post on screen as \"author:caption\" or \"none\":"
        }
    }
}
