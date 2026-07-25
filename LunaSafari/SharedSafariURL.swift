//
//  SharedSafariURL.swift
//  LunaSafari
//

import Foundation

/// Writes the last-seen Safari URL into the shared App Group defaults.
/// The main app reads these keys via `SafariURLStore` (kept as a separate copy
/// because the extension and app don't share a framework in this small project).
enum SharedSafariURL {
    // Read from the build-injected Info.plist key (see Config/Luna.xcconfig) so the
    // App Group id has a single source of truth shared with the app + other extensions.
    // This target doesn't link the package, so the lookup is inlined here.
    static let appGroupID = SafariAppGroup.id
    static let urlKey = "lastSafariURL"
    static let dateKey = "lastSafariURLDate"
    static let recentHistoryKey = "safariRecentURLHistory.v1"
    static let recentHistoryLimit = 20
    static let sharedSafariSetupKey = "setup.safari.hasRun.shared"
    static let centralSafariSetupKey = "setup.safari.hasRun.luna"

    static func record(_ urlString: String) {
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(urlString, forKey: urlKey)
        defaults?.set(Date().timeIntervalSince1970, forKey: dateKey)
        // Keep one useful entry per raw URL. Revisiting a page moves it to the
        // front without normalizing or otherwise rewriting what Safari reported.
        var recent = defaults?.stringArray(forKey: recentHistoryKey) ?? []
        recent.removeAll { $0 == urlString }
        recent.insert(urlString, at: 0)
        defaults?.set(Array(recent.prefix(recentHistoryLimit)), forKey: recentHistoryKey)
    }

    /// Records that this containing app's extension has actually executed.
    /// Reader/Downloader/Price Tracker share completion; bare central Luna is
    /// deliberately independent.
    static func recordExtensionRun(isCentral: Bool) {
        UserDefaults(suiteName: appGroupID)?.set(
            true, forKey: isCentral ? centralSafariSetupKey : sharedSafariSetupKey)
    }

    // The already-unlocked article HTML captured in Safari, handed to the app so it
    // renders that content instead of re-fetching (which would re-lock). The app reads
    // these via `SafariContentStore`, matching the URL and a short freshness window.
    static let unlockedURLKey = "safariUnlockedURL"
    static let unlockedHTMLKey = "safariUnlockedHTML"
    static let unlockedDateKey = "safariUnlockedDate"

    static func recordUnlockedContent(_ urlString: String, html: String) {
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(urlString, forKey: unlockedURLKey)
        defaults?.set(html, forKey: unlockedHTMLKey)
        defaults?.set(Date().timeIntervalSince1970, forKey: unlockedDateKey)
    }
}
