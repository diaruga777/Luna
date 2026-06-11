//
//  SharedSafariURL.swift
//  ClipSafari
//

import Foundation

/// Writes the last-seen Safari URL into the shared App Group defaults.
/// The main app reads these keys via `SafariURLStore` (kept as a separate copy
/// because the extension and app don't share a framework in this small project).
enum SharedSafariURL {
    static let appGroupID = "group.com.hpiddy.clip"
    static let urlKey = "lastSafariURL"
    static let dateKey = "lastSafariURLDate"

    static func record(_ urlString: String) {
        let defaults = UserDefaults(suiteName: appGroupID)
        defaults?.set(urlString, forKey: urlKey)
        defaults?.set(Date().timeIntervalSince1970, forKey: dateKey)
    }
}
