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
        // Each prompt asks for the exact ordered fields "Save from App" expects
        // for that app, separated by " ; " so the shortcut can split them into
        // the values list. "none" means nothing identifiable is on screen.
        switch platform {
        case .youtube:
            return "Return the channel name and video title of the YouTube video on screen as \"channel ; title\", or \"none\":"
        case .music:
            return "Return the artist and track title of the song on screen as \"artist ; title\", or \"none\":"
        case .podcast:
            return "Return the show name and episode title of the podcast on screen as \"show ; episode title\", or \"none\":"
        case .bluesky:
            return "Return the author handle and a distinctive phrase from the Bluesky post on screen as \"handle ; phrase\", or \"none\":"
        case .reddit:
            return "Return the subreddit, post title, and author of the Reddit post on screen as \"subreddit ; title ; author\", or \"none\":"
        case .x, .tiktok, .instagram, .facebook:
            return "Return the author handle and a distinctive phrase from the post on screen as \"handle ; phrase\", or \"none\":"
        }
    }
}
