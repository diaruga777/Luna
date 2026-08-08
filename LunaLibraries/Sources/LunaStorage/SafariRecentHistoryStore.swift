//
//  SafariRecentHistoryStore.swift
//  LunaStorage
//

import LunaAppConfig
import Foundation

/// The raw, cross-app Safari trail written by every Luna Safari extension.
///
/// The Safari extension target cannot link LunaStorage, so its matching writer
/// duplicates only `historyKey` and the array format in `SharedSafariURL`.
public final class SafariRecentHistoryStore {
    public static let shared = SafariRecentHistoryStore()
    public static let historyKey = "safariRecentURLHistory.v1"
    public static let limit = 20

    private let defaults: UserDefaults

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: AppConfig.appGroupID)
            ?? .standard
    }

    /// Newest first. Values are deliberately raw URL strings: classification
    /// and preview metadata belong to each app's independent evaluation cache.
    ///
    /// Repeats are collapsed BEFORE `limit` applies — the writer already keeps one
    /// entry per raw URL, so this only catches a trail left by an older extension
    /// build, but a duplicate must never cost a slot. First occurrence wins, which
    /// on a newest-first trail is the most recent visit.
    public var URLs: [String] {
        var seen: Set<String> = []
        return (defaults.stringArray(forKey: Self.historyKey) ?? [])
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .prefix(Self.limit)
            .map { $0 }
    }
}

