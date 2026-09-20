//
//  AppNamePlatform.swift
//  LunaIntents
//

import LunaModels
import Foundation

/// Maps the current-app name (from Shortcuts' "Get Current App") to a content
/// platform, and supplies the screen-extraction prompt per platform.
/// Shared by the Provide Context and Save intents.
public enum AppNamePlatform {

    /// Whether the current app is one Luna knows how to save from — a recognized
    /// content platform, Safari (whose plain page URL is saved directly), or the
    /// Shortcuts app (which carries no content of its own to save).
    /// Unknown apps are unsupported.
    public static func isSupported(forAppName app: String) -> Bool {
        platform(forAppName: app) != nil || isSafari(forAppName: app) || isShortcuts(forAppName: app)
    }

    /// Whether the frontmost app is any app in the Luna family.
    ///
    /// The Action Button intents must not inspect a Luna app's screen: links
    /// shown there are already owned by the shared store, and the app itself
    /// is not one of the external surfaces these intents capture from.
    /// Compared as a whole normalized name because "Luna" is a prefix of the
    /// other three, so substring matching would fold unrelated names together.
    public static func isLunaApp(_ app: String?) -> Bool {
        guard let name = normalizedName(app) else { return false }
        return LunaApp.allCases.contains {
            normalizedName($0.displayName) == name
        }
    }

    /// Whether the frontmost app is a DIFFERENT app in the Luna family.
    ///
    /// All four apps register the same two Action Button intents, so a press
    /// made while a sibling owns the screen can reach any of them. Nothing good
    /// comes of acting on it: the sibling's own UI is not a page to save, and a
    /// link visible inside it is already in the shared store, filed under the
    /// app that owns its kind. Both intents therefore treat this as unhandled
    /// and stop — see `ProvideContextIntent` / `SaveIntent`.
    ///
    /// This narrower predicate remains useful to callers that need to
    /// distinguish the running app from its siblings.
    public static func isSiblingLunaApp(
        _ app: String?, running: LunaApp = .current
    ) -> Bool {
        guard isLunaApp(app), let name = normalizedName(app) else { return false }
        return LunaApp.allCases.contains {
            $0 != running && normalizedName($0.displayName) == name
        }
    }

    private static func normalizedName(_ app: String?) -> String? {
        guard let app else { return nil }
        let collapsed = app
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .lowercased()
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Whether the app is Safari (supported, but needs no model prompt — the tracked
    /// page URL is saved instead).
    public static func isSafari(forAppName app: String) -> Bool {
        app.lowercased().contains("safari")
    }

    /// Whether the app is Shortcuts (supported, but needs no model prompt —
    /// there is no meaningful screenshot of Shortcuts' own UI to analyze).
    public static func isShortcuts(forAppName app: String) -> Bool {
        app.lowercased().contains("shortcuts")
    }

    /// The platform for an app name, or nil (Safari / unknown → plain URL).
    public static func platform(forAppName app: String) -> ContentPlatform? {
        let name = app.lowercased()
        if name.contains("bluesky") { return .bluesky }
        if name.contains("tiktok") { return .tiktok }
        if name.contains("reddit") { return .reddit }
        if name.contains("instagram") { return .instagram }
        if name.contains("facebook") { return .facebook }
        if name == "x" || name.contains("twitter") { return .x }
        return nil
    }

    /// The screen-extraction prompt for pulling identifying metadata from a
    /// screenshot of `app`, or nil when none applies (Safari — see
    /// `safariScreenPrompt` — and unknown apps). The
    /// Save intent runs prompt+screenshot through the in-process vision session
    /// and parses the model's single response string.
    ///
    /// Each prompt instructs the model to return one line containing exactly the
    /// fields the Save intent parses for that app, joined by " ; " — matching
    /// `SaveResponseParsing.parseFields`. "none" means nothing identifiable is on
    /// screen; the save intent treats it (and any error/empty response) as nothing
    /// to save.
    public static func screenPrompt(forAppName app: String) -> String? {
        guard let platform = platform(forAppName: app) else { return nil }
        switch platform {
        case .bluesky:
            return "Look at the Bluesky post on screen. Answer with ONE line in exactly this form: handle ; phrase. handle is the author's @handle as shown. phrase is 5 to 10 words copied verbatim from the post's text, chosen to be distinctive. Use \" ; \" (space, semicolon, space) as the only separator. No quotes, no labels, no other text. If no post is identifiable, answer exactly: none"
        case .reddit:
            return "Look at the Reddit post on screen. Answer with ONE line in exactly this form: subreddit ; title ; author. subreddit is the community name without r/. title is the post title copied verbatim. author is the poster's username without u/. Use \" ; \" (space, semicolon, space) as the only separator. No quotes, no labels, no other text. If no post is identifiable, answer exactly: none"
        case .x, .tiktok, .instagram, .facebook:
            return "Look at the social post on screen. Answer with ONE line in exactly this form: handle ; phrase. handle is the author's @handle or username as shown. phrase is 5 to 10 words copied verbatim from the post's own text, not from a reply or a quoted post. If the post's date is visible, append \" ; \" and that date as shown (for example Jun 14, 2026). Use \" ; \" (space, semicolon, space) as the only separator. No quotes, no labels, no other text. If no post is identifiable, answer exactly: none"
        case .youtube, .web:
            return nil
        }
    }

    /// The screen-extraction prompt for a Safari webpage: no platform-specific
    /// fields, just the page's title and site/publication name.
    public static let safariScreenPrompt = "Look at the web page on screen. Answer with ONE line in exactly this form: title ; site. title is the page's headline or title copied verbatim. site is the publication or site name if shown, else the domain from the address bar. Use \" ; \" (space, semicolon, space) as the only separator. No quotes, no labels, no other text. If no web page is identifiable, answer exactly: none"
}
