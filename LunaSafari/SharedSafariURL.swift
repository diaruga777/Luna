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

    static func record(_ urlString: String) {
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(urlString, forKey: urlKey)
        defaults?.set(Date().timeIntervalSince1970, forKey: dateKey)
    }
}
