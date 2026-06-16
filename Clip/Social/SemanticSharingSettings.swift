//
//  SemanticSharingSettings.swift
//  Clip
//

import Foundation

/// Flag for the experimental on-device semantic sharing suggestions. OFF by
/// default: building the embedding index runs a Natural Language model, which
/// is only ever done in the MAIN APP (never the memory-limited App-Intent
/// runner). Stored in the App Group so every process reads the same value.
enum SemanticSharingSettings {
    private static let enabledKey = "semanticSharingEnabled"
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ReadingListStore.appGroupID) ?? .standard
    }

    static var isEnabled: Bool {
        get { defaults.bool(forKey: enabledKey) }
        set { defaults.set(newValue, forKey: enabledKey) }
    }
}
