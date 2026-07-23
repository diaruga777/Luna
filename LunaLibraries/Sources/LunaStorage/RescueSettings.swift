//
//  RescueSettings.swift
//  LunaStorage
//

import Foundation
import LunaAppConfig

/// The user-facing consent gate for automatic URL rescue. App-Group-backed (so
/// every surface + the settings screen share one value), default ON. Mirrors
/// `AudioSettings`' enum-namespace-over-UserDefaults pattern.
///
/// This gate governs ONLY the automatic (inline foreground + background sweep)
/// rescue. Regardless of it, the failed-item one-shot rescue affordance is
/// always offered — that per-URL tap IS its own consent.
public enum RescueSettings {
    private static var defaults: UserDefaults {
        UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard
    }

    private static let autoRescueKey = "rescueFailedSavesEnabled"

    /// "Rescue failed saves with Apple Intelligence." Default true.
    public static var isAutoRescueEnabled: Bool {
        get { (defaults.object(forKey: autoRescueKey) as? Bool) ?? true }
        set { defaults.set(newValue, forKey: autoRescueKey) }
    }
}
