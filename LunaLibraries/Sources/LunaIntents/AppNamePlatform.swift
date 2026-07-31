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

    /// Whether the frontmost app is a DIFFERENT app in the Luna family.
    ///
    /// All four apps register the same two Action Button intents, so a press
    /// made while a sibling owns the screen can reach any of them. Nothing good
    /// comes of acting on it: the sibling's own UI is not a page to save, and a
    /// link visible inside it is already in the shared store, filed under the
    /// app that owns its kind. Both intents therefore treat this as unhandled
    /// and stop — see `ProvideContextIntent` / `SaveIntent`.
    ///
    /// The running app itself is deliberately NOT a match: a press inside the
    /// app you're holding keeps whatever behavior its screen affords.
    /// Compared as a whole normalized name because "Luna" is a prefix of the
    /// other three, so substring matching would fold them together.
    public static func isSiblingLunaApp(
        _ app: String?, running: LunaApp = .current
    ) -> Bool {
        guard let name = normalizedName(app) else { return false }
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
            return "Respond with a single line for the Bluesky post on screen, in the exact form \"handle ; phrase\" (the author handle, then \" ; \", then a distinctive phrase from the post). If nothing identifiable is on screen, respond with exactly \"none\"."
        case .reddit:
            return "Respond with a single line for the Reddit post on screen, in the exact form \"subreddit ; title ; author\" (the subreddit, then \" ; \", then the post title, then \" ; \", then the author). If nothing identifiable is on screen, respond with exactly \"none\"."
        case .x, .tiktok, .instagram, .facebook:
            return "Respond with a single line for the post on screen as \"handle ; phrase\" — the author handle, then \" ; \", then a short EXACT quote (5–10 words copied verbatim) from the post's text. If the post's date or time is visible, append \" ; \" and that date (e.g. \"Jun 14, 2026\"). If nothing identifiable is on screen, respond with exactly \"none\"."
        case .youtube, .web:
            return nil
        }
    }

    /// The screen-extraction prompt for a Safari webpage: no platform-specific
    /// fields, just the page's title and site/publication name.
    public static let safariScreenPrompt = "Respond with a single line for the webpage on screen, in the exact form \"title ; site\" — the page's title, then \" ; \", then the site or publication name if visible, else the domain. If no webpage is identifiable, respond with exactly \"none\"."
}
