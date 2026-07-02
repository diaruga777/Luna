//
//  SafariContentStore.swift
//  Luna
//

import LunaAppConfig
import Foundation

/// Reads the already-unlocked article HTML the LunaSafari web extension captured in
/// Safari (see LunaSafari/SharedSafariURL.swift `recordUnlockedContent`), so the app
/// can render that content as prefetched HTML instead of re-fetching a page that would
/// re-lock outside Safari.
public enum SafariContentStore {
    public static let appGroupID = AppConfig.appGroupID
    static let urlKey = "safariUnlockedURL"
    static let htmlKey = "safariUnlockedHTML"
    static let dateKey = "safariUnlockedDate"

    /// How long a captured page stays usable — long enough to cover the Safari→app
    /// hand-off, short enough that a stale capture is never applied to a later open.
    static let freshness: TimeInterval = 300

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
