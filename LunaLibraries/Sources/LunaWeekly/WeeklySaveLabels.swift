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
        switch (app, monthTier) {
        case (.luna, false): return L10n.string("Save of the week")
        case (.luna, true): return L10n.string("Save of the month")
        case (.reader, false): return L10n.string("Read of the week")
        case (.reader, true): return L10n.string("Read of the month")
        case (.downloader, false): return L10n.string("Download of the week")
        case (.downloader, true): return L10n.string("Download of the month")
        case (.priceTracker, false): return L10n.string("Deal of the week")
        case (.priceTracker, true): return L10n.string("Deal of the month")
        }
    }

    /// The key-holder's long-press verb.
    public static func promoteMenuTitle(for app: LunaApp = .current) -> String {
        switch app {
        case .luna: return L10n.string("Promote to Save of the Week")
        case .reader: return L10n.string("Promote to Read of the Week")
        case .downloader: return L10n.string("Promote to Download of the Week")
        case .priceTracker: return L10n.string("Promote to Deal of the Week")
        }
    }

    /// The long-press verb everyone gets, key-holder included. Deliberately
    /// app-neutral: a proposal travels to the curator, who may be running a
    /// different app.
    public static var proposeMenuTitle: String {
        L10n.string("Propose Save of the Week")
    }
}
