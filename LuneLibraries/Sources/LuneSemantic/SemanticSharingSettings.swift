//
//  SemanticSharingSettings.swift
//  Lune
//

import LuneStorage
import Foundation

/// Settings for the experimental on-device semantic sharing suggestions.
///
/// A single `sensitivity` (0...1) controls everything: `0` is off ("never"
/// suggest), and higher values suggest more eagerly ("often") by lowering the
/// content-similarity threshold. OFF by default — building the embedding index
/// runs a Natural Language model, which is only ever done in the MAIN APP
/// (never the memory-limited App-Intent runner). Stored in the App Group so
/// every process reads the same value.
public enum SemanticSharingSettings {
    private static let sensitivityKey = "semanticSharingSensitivity"
    /// Pre-slider boolean flag, read once for migration.
    private static let legacyEnabledKey = "semanticSharingEnabled"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: ReadingListStore.appGroupID) ?? .standard
    }

    /// 0 = off ("never"), 1 = most eager ("often"). Clamped to 0...1.
    public static var sensitivity: Double {
        get {
            if let stored = defaults.object(forKey: sensitivityKey) as? Double {
                return min(1, max(0, stored))
            }
            // Migrate the old on/off flag: a user who'd enabled it lands mid-slider.
            return defaults.bool(forKey: legacyEnabledKey) ? 0.5 : 0
        }
        set { defaults.set(min(1, max(0, newValue)), forKey: sensitivityKey) }
    }

    /// Whether suggestions are on at all.
    public static var isEnabled: Bool { sensitivity > 0 }

    /// Minimum cosine similarity to suggest sharing, derived from `sensitivity`.
    /// Sentence-embedding cosines for clearly related text sit high; raising the
    /// floor (low sensitivity) makes suggestions rare and confident, lowering it
    /// (high sensitivity) makes them frequent. Range chosen to be conservative —
    /// even "often" stays above the noise floor for unrelated text.
    public static let strictestThreshold: Float = 0.82
    public static let loosestThreshold: Float = 0.62

    public static var similarityThreshold: Float { threshold(forSensitivity: sensitivity) }

    /// Pure mapping from a sensitivity (0...1) to a cosine threshold, for testing.
    public static func threshold(forSensitivity sensitivity: Double) -> Float {
        let fraction = Float(min(1, max(0, sensitivity)))
        return strictestThreshold - fraction * (strictestThreshold - loosestThreshold)
    }
}
