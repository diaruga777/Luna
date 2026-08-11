//
//  SafariSuggestionSettings.swift
//  Luna
//

import LunaStorage
import Foundation
import LunaModels

/// When the Safari extension shows its "Read in Luna" button. Stored in the App
/// Group so the extension's native handler can read it (the extension and app
/// don't share a framework — the handler reads the raw `rawValue` string under
/// `SafariSuggestionSettings.key`). Defaults to `.all`.
enum SafariSuggestionMode: String, CaseIterable {
    /// Never show the button.
    case never
    /// Show on every article page.
    case all
    /// Show only on pages the extension detects as paywalled ("locked").
    case onlyLocked

    var displayName: String {
        switch self {
        case .never: return L10n.string("Common_never")
        case .all: return L10n.string("Settings_safariSuggestion_allArticlesOption")
        case .onlyLocked: return L10n.string("Settings_safariSuggestion_onlyLockedOption")
        }
    }
}

enum SafariSuggestionSettings {
    /// App Group key the extension's native handler reads (raw `SafariSuggestionMode`).
    static let key = "safariSuggestionMode"

    /// App Group key for the in-page video player (`claudedocs/safari-extension.md`).
    /// ABSENT means ON: the player is the shipped behavior on a media page, and a
    /// user who has never opened Settings must get it — so the extension reads
    /// this as "off only when it says so", and nothing writes a default.
    static let videoPlayerKey = "safariVideoPlayerEnabled"

    /// App Group key for the extension's cookie auto-decline
    /// (`claudedocs/safari-extension.md`). Same ABSENT-means-ON contract as the
    /// player: answering "necessary cookies only" is the shipped behavior and
    /// nothing writes a default, so the extension treats it as "off only when it
    /// says so". Only the two article apps expose the control and only their
    /// extensions read it — the Downloader's and Price Tracker's suppression
    /// stays always-on, so a Reader "off" can never reach through the shared
    /// suite and silence them too.
    static let cookieAutoDeclineKey = "safariCookieAutoDeclineEnabled"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ReadingListStore.appGroupID) ?? .standard
    }

    static var mode: SafariSuggestionMode {
        get { defaults.string(forKey: key).flatMap(SafariSuggestionMode.init(rawValue:)) ?? .all }
        set { defaults.set(newValue.rawValue, forKey: key) }
    }

    /// Whether a recognized media page opens the in-page player. Off leaves the
    /// pill exactly as it behaved before the player existed: a tap hands the link
    /// to the app. Only the two media-handling apps show the control, and only
    /// their extensions ever ask.
    static var videoPlayerEnabled: Bool {
        get { defaults.object(forKey: videoPlayerKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: videoPlayerKey) }
    }

    /// Whether the Safari extension answers a site's cookie question for the
    /// user ("necessary cookies only" / reject-all, never accept). Off leaves
    /// the dialog on screen and untouched — the pre-paint hide reverts too, so
    /// the user answers it themselves. The rest of the annoyance layer
    /// (newsletter popovers, app-install nags, scroll recovery) is unaffected.
    static var cookieAutoDeclineEnabled: Bool {
        get { defaults.object(forKey: cookieAutoDeclineKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: cookieAutoDeclineKey) }
    }
}
