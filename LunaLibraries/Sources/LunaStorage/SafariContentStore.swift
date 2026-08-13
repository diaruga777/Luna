//
//  SafariContentStore.swift
//  Luna
//

import LunaAppConfig
import Foundation

/// The already-unlocked article HTML the LunaSafari web extension captured in
/// Safari, so the app can render that content as prefetched HTML instead of
/// re-fetching a page that would re-lock outside Safari.
///
/// The extension writes it (`record`) and the app consumes it (`take`).
public enum SafariContentStore {
    public static let appGroupID = AppConfig.appGroupID
    static let urlKey = "safariUnlockedURL"
    static let htmlKey = "safariUnlockedHTML"
    static let dateKey = "safariUnlockedDate"

    /// How long a captured page stays usable — long enough to cover the Safari→app
    /// hand-off, short enough that a stale capture is never applied to a later open.
    static let freshness: TimeInterval = 300

    /// Stores the page the content script just unlocked, for the app to pick up
    /// on the hand-off that follows.
    public static func record(_ urlString: String, html: String, at date: Date = Date()) {
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(urlString, forKey: urlKey)
        defaults?.set(html, forKey: htmlKey)
        defaults?.set(date.timeIntervalSince1970, forKey: dateKey)
    }

    /// The unlocked HTML for `urlString` if it was captured recently and for THIS exact
    /// URL, else nil. Consumes it (single use) so it can't leak onto a later open.
    public static func take(for urlString: String) -> String? {
        let defaults = UserDefaults(suiteName: appGroupID)
        guard let storedURL = defaults?.string(forKey: urlKey), storedURL == urlString,
              let html = defaults?.string(forKey: htmlKey),
              let timestamp = defaults?.object(forKey: dateKey) as? Double,
              Date().timeIntervalSince1970 - timestamp < freshness
        else { return nil }
        defaults?.removeObject(forKey: urlKey)
        defaults?.removeObject(forKey: htmlKey)
        defaults?.removeObject(forKey: dateKey)
        return html
    }
}
