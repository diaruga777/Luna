//
//  SafariSuggestionSettings.swift
//  Luna
//

import LunaStorage
import Foundation
import LunaModels

/// When the Safari extension shows its "Read in Luna" button. Stored in the App
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
        case .never: return L10n.string("Common_never")
        case .all: return L10n.string("Settings_safariSuggestion_allArticlesOption")
        case .onlyLocked: return L10n.string("Settings_safariSuggestion_onlyLockedOption")
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
