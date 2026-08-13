//
//  PriceTrackerSaveAnnouncement.swift
//  Luna
//

import Foundation

public extension Notification.Name {
    /// Posted when an interactive save (paste/manual/app intent) created or merged
    /// a price tracker, so the foreground saves list can present its editor with
    /// a "Read instead" → save-as-article fallback. `userInfo`: `itemID: UUID`,
    /// `isMerge: Bool`, `highlightedURL: String?`.
    ///
    /// Lives in LunaModels so both posters can see it without re-coupling: the
    /// product ingest handler (LunaPriceUI) posts it for created/merged trackers,
    /// and `SavesIngestor`'s re-save dedup (LunaReadingList) posts it when a
    /// re-saved URL merges into an existing tracker.
    static let priceTrackerSavedInteractively =
        Notification.Name("priceTrackerSavedInteractively")
}

/// Announces a just-created/merged price tracker from an interactive in-app
/// save (paste/manual) so the foreground list can present the price editor.
/// App Intents, extensions, and background/friend saves must never trigger UI.
public enum PriceTrackerSaveAnnouncement {
    public static func post(
        itemID: UUID, source: CaptureSource, isMerge: Bool, highlightedURL: String?
    ) {
        switch source {
        case .paste, .manual:
            break
        case .appIntent, .shareSheet, .friendShare, .email:
            return
        }
        let userInfo: [String: Any] = [
            "itemID": itemID, "isMerge": isMerge,
            "highlightedURL": highlightedURL as Any,
        ]
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .priceTrackerSavedInteractively, object: nil, userInfo: userInfo)
        }
    }
}
