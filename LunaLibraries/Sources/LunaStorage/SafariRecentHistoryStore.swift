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
    public var URLs: [String] {
        (defaults.stringArray(forKey: Self.historyKey) ?? [])
            .filter { !$0.isEmpty }
            .prefix(Self.limit)
            .map { $0 }
    }
}

