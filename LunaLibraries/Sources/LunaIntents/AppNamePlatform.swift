//
//  AppNamePlatform.swift
//  Luna
//

import LunaModels
import Foundation

/// Maps the current-app name (from Shortcuts' "Get Current App") to a content
/// platform, and supplies the screen-extraction prompt per platform.
/// Shared by the generic save intent and the screen-prompt intent.
public enum AppNamePlatform {

    /// Whether the current app is one Luna knows how to save from — a recognized
    /// content platform, Safari (whose plain page URL is saved directly), or the
    /// Shortcuts app (the Action Button onboarding shortcut's own first run — no
    /// content to save, `SaveFromAppIntent` intercepts it before any save logic
    /// runs). Unknown apps are unsupported; the screen-prompt intent returns
    /// "unsupported" for them.
    public static func isSupported(forAppName app: String) -> Bool {
        platform(forAppName: app) != nil || isSafari(forAppName: app) || isShortcuts(forAppName: app)
    }

    /// Whether the app is Safari (supported, but needs no model prompt — the tracked
    /// page URL is saved instead).
    public static func isSafari(forAppName app: String) -> Bool {
        app.lowercased().contains("safari")
    }

    /// Whether the app is Shortcuts (supported, but needs no model prompt — the
    /// Action Button onboarding shortcut's first run carries no content of its
    /// own; see `ActionButtonOnboardingStore.handleProvideContextInvoked`).
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
    /// screenshot of `app`, or nil when none applies (Safari, unknown apps). The
    /// caller appends the screenshot and runs prompt+image through an image model,
    /// then passes the model's single response string straight to "Save from App".
    ///
    /// Each prompt instructs the model to return one line containing exactly the
    /// fields "Save from App" parses for that app, joined by " ; " — matching
    /// `SaveFromAppIntent.parseFields`. "none" means nothing identifiable is on
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
        }
    }

    /// The screen-extraction prompt for a Safari webpage: no platform-specific
    /// fields, just the page's title and site/publication name.
    public static let safariScreenPrompt = "Respond with a single line for the webpage on screen, in the exact form \"title ; site\" — the page's title, then \" ; \", then the site or publication name if visible, else the domain. If no webpage is identifiable, respond with exactly \"none\"."
}
