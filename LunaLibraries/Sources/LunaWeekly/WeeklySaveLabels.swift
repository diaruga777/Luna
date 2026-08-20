//
//  WeeklySaveLabels.swift
//  LunaWeekly
//

import Foundation
import LunaModels

/// The row's attribution. Every app uses the same label for every entry kind.
public enum WeeklySaveLabels {

    /// The attribution shown on every curated row.
    public static func subtitle(for app: LunaApp = .current) -> String {
        L10n.string("Weekly_subtitle", for: app)
    }

    /// The key-holder's long-press verb.
    public static func promoteMenuTitle(for app: LunaApp = .current) -> String {
        L10n.string("Weekly_promoteMenuTitle", for: app)
    }

    /// The long-press verb everyone gets, key-holder included. Deliberately
    /// app-neutral: a proposal travels to the curator, who may be running a
    /// different app.
    public static var proposeMenuTitle: String {
        L10n.string("Weekly_proposeMenuTitle")
    }
}
