//
//  IntentSaveVerification.swift
//  LunaIntents
//

import LunaModels
import Foundation

/// Checks that a save press actually left usable content in the app.
///
/// An App Intent must never report success while the app holds nothing (or holds
/// only a failure): the Shortcut exits looking like it worked and the user finds
/// an empty list. `SavesIngestor.SavePressResult` alone can't tell us —
/// `.saved` is returned for a placeholder whose ingest may later fail — so the
/// intent re-reads the store afterward and runs the item's state through here.
public enum IntentSaveVerification {

    /// What the intent should report instead of success.
    public enum Failure: Equatable {
        /// Nothing is in the store for this press at all (an unusable URL, or a
        /// gate that discarded the placeholder).
        case nothingSaved
        /// The item exists but its content couldn't be fetched or extracted —
        /// it's parked in `.failed` and there's nothing to read.
        case contentUnavailable
    }

    /// The verdict for the item's state as it stands in the store right now.
    /// `nil` state means no item was found.
    ///
    /// - `.pending` passes: the save is persisted and its ingest is still
    ///   running (the intent's own 12 s race can expire first), so the item is
    ///   in the app and will finish or be retried on the next launch.
    /// - `.needsCaptcha` passes deliberately: a hard-paywalled article is SAVED,
    ///   with its title, behind the interactive "tap to unlock" affordance. That
    ///   is a successful save, not a failure (see `SavedItem.State`).
    public static func failure(forState state: SavedItem.State?) -> Failure? {
        guard let state else { return .nothingSaved }
        switch state {
        case .link, .ready, .pending, .needsCaptcha: return nil
        case .failed: return .contentUnavailable
        }
    }
}
