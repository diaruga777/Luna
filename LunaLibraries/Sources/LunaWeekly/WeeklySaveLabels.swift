//
//  WeeklySaveLabels.swift
//  LunaWeekly
//

import Foundation
import LunaModels

/// The row's noun. Each faceted app renames the thing it collects; the central
/// Luna app keeps "Save" for all three kinds as it cycles, because the noun
/// belongs to the app, not to the kind.
public enum WeeklySaveLabels {

    /// The subtitle suffix — "Save of the week", "Read of the month", …
    public static func subtitle(
        for app: LunaApp = .current, monthTier: Bool
    ) -> String {
        monthTier
            ? L10n.string("Weekly_subtitle_month", for: app)
            : L10n.string("Weekly_subtitle_week", for: app)
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
