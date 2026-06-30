//
//  SafariSuggestionSettings.swift
//  Clip
//

import ClipStorage
import Foundation

/// When the Safari extension shows its "Read in Quartz" button. Stored in the App
/// Group so the extension's native handler can read it (the extension and app
/// don't share a framework — the handler reads the raw `rawValue` string under
/// `SafariSuggestionSettings.key`). Defaults to `.all`.
enum SafariSuggestionMode: String, CaseIterable {
    /// Never show the button.
    case never
    /// Show on every article page.
    case all
    /// Show only on pages the extension detects as paywalled ("locked").
    case onlyLocked

    var displayName: String {
        switch self {
        case .never: return "Never"
        case .all: return "All Articles"
        case .onlyLocked: return "Locked Only"
        }
    }
}

enum SafariSuggestionSettings {
    /// App Group key the extension's native handler reads (raw `SafariSuggestionMode`).
    static let key = "safariSuggestionMode"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ReadingListStore.appGroupID) ?? .standard
    }

    static var mode: SafariSuggestionMode {
        get { defaults.string(forKey: key).flatMap(SafariSuggestionMode.init(rawValue:)) ?? .all }
        set { defaults.set(newValue.rawValue, forKey: key) }
    }
}
