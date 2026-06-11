//
//  SafariURLStore.swift
//  Clip
//

import Foundation

/// Reads the last Safari URL recorded by the ClipSafari web extension's native
/// handler (see ClipSafari/SharedSafariURL.swift, which writes these keys).
enum SafariURLStore {
    static let appGroupID = "group.com.hpiddy.clip"
    static let urlKey = "lastSafariURL"
    static let dateKey = "lastSafariURLDate"

    static var lastURL: String? {
        UserDefaults(suiteName: appGroupID)?.string(forKey: urlKey)
    }

    static var lastDate: Date? {
        guard let interval = UserDefaults(suiteName: appGroupID)?.object(forKey: dateKey) as? Double
        else { return nil }
        return Date(timeIntervalSince1970: interval)
    }
}
