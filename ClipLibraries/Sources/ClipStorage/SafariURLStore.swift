//
//  SafariURLStore.swift
//  Clip
//

import ClipAppConfig
import Foundation

/// Reads the last Safari URL recorded by the ClipSafari web extension's native
/// handler (see ClipSafari/SharedSafariURL.swift, which writes these keys).
public enum SafariURLStore {
    public static let appGroupID = AppConfig.appGroupID
    public static let urlKey = "lastSafariURL"
    public static let dateKey = "lastSafariURLDate"

    public static var lastURL: String? {
        UserDefaults(suiteName: appGroupID)?.string(forKey: urlKey)
    }

    public static var lastDate: Date? {
        guard let interval = UserDefaults(suiteName: appGroupID)?.object(forKey: dateKey) as? Double
        else { return nil }
        return Date(timeIntervalSince1970: interval)
    }
}
