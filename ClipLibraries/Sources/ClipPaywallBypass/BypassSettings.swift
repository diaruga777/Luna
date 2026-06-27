//
//  BypassSettings.swift
//  ClipPaywallBypass
//

import Foundation

/// The one bypass-related user setting the pure strategy logic needs to read:
/// whether the experimental extra (non-archive) paywall-unlock strategies are
/// enabled. Reads the same App-Group key the app's `ReaderSettings` writes, so the
/// value is consistent without the bypass layer depending on the UI/settings layer.
public enum BypassSettings {
    private static let appGroupID = "group.com.hpiddy.clip"
    private static let nonArchiveBypassKey = "nonArchiveBypassEnabled"

    /// OFF by default (no key present → `bool(forKey:)` returns false), matching
    /// `BypassSettings.nonArchiveBypassEnabled`.
    public static var nonArchiveBypassEnabled: Bool {
        (UserDefaults(suiteName: appGroupID) ?? .standard).bool(forKey: nonArchiveBypassKey)
    }
}
