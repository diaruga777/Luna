//
//  SafariURLStore.swift
//  Luna
//

import LunaAppConfig
import Foundation

/// Reads the last Safari URL recorded by the LunaSafari web extension's native
/// handler (see LunaSafari/SharedSafariURL.swift, which writes these keys).
public enum SafariURLStore {
    public static let appGroupID = AppConfig.appGroupID
    public static let urlKey = "lastSafariURL"
    public static let dateKey = "lastSafariURLDate"

    /// How long a captured Safari URL is treated as "the user is still on
    /// that page" by `isFresh` — a generous window (Provide Context's Safari
    /// case: fresh → save immediately, stale → fall through to a screenshot).
    public static let freshnessWindow: TimeInterval = 72 * 60 * 60

    /// Overridable so tests can inject an isolated App-Group suite instead of
    /// the real container — mirrors the constructor-injected `defaults` other
    /// stores in this module take, adapted to this store's all-static shape
    /// (its many call sites read it with no instance in hand). Production
    /// code never sets this; it always resolves the real App Group.
    static var testDefaultsOverride: UserDefaults?

    private static var resolvedDefaults: UserDefaults? {
        resolvedAppGroupDefaults(appGroupID: appGroupID, testOverride: testDefaultsOverride)
    }

    public static var lastURL: String? {
        resolvedDefaults?.string(forKey: urlKey)
    }

    public static var lastDate: Date? {
        guard let interval = resolvedDefaults?.object(forKey: dateKey) as? Double
        else { return nil }
        return Date(timeIntervalSince1970: interval)
    }

    /// True iff `lastURL` is present (non-empty) and `lastDate` is within
    /// `window` of `now` (either direction, to tolerate clock skew).
    public static func isFresh(within window: TimeInterval = freshnessWindow, now: Date = Date()) -> Bool {
        guard let lastURL, !lastURL.isEmpty, let lastDate else { return false }
        return abs(now.timeIntervalSince(lastDate)) <= window
    }
}
