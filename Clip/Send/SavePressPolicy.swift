//
//  SavePressPolicy.swift
//  Clip
//

import Foundation

/// Decides what a save press means. Pure logic so the full matrix is testable:
/// first press saves; a second press within the window sends to every ereader
/// in double-save mode (skipping any sent in the past day); everything else
/// about an already-listed URL is ignored until the user deletes and re-saves.
enum SavePressPolicy {

    enum Decision: Equatable {
        /// URL not in the list — save and ingest it.
        case saveNew
        /// Double press detected — send the existing article to these ereader
        /// destinations (by id).
        case sendToEreaders(destinationIDs: [String])
        /// Duplicate press — do nothing.
        case ignore
    }

    /// How close together two presses must be to count as a double save.
    static let doublePressWindow: TimeInterval = 12
    /// Articles sent within this interval aren't re-sent by a double press.
    static let resendCooldown: TimeInterval = 24 * 60 * 60

    /// - Parameters:
    ///   - existingItem: the list item for this URL, nil if not saved yet.
    ///   - previousPressDate: when this URL was last saved/pressed (the item's
    ///     `dateAdded` if this is the first repeat press).
    ///   - doubleSaveDestinationIDs: destinations that are configured AND in
    ///     double-save mode right now.
    static func decide(
        existingItem: ReadingListItem?,
        previousPressDate: Date?,
        now: Date,
        doubleSaveDestinationIDs: [String]
    ) -> Decision {
        guard let existingItem else { return .saveNew }
        // Videos have no ereader EPUB target — every repeat press is a no-op.
        guard !existingItem.isYouTubeVideo else { return .ignore }

        let isDoublePress = previousPressDate.map {
            now.timeIntervalSince($0) < doublePressWindow
        } ?? false
        guard isDoublePress, !doubleSaveDestinationIDs.isEmpty else { return .ignore }

        // Skip destinations already sent within the cooldown.
        let eligible = doubleSaveDestinationIDs.filter { destinationID in
            let sentRecently = existingItem.sendState(for: destinationID) == .sent
                && (existingItem.dateSent(for: destinationID)
                    .map { now.timeIntervalSince($0) < resendCooldown } ?? false)
            return !sentRecently
        }
        return eligible.isEmpty ? .ignore : .sendToEreaders(destinationIDs: eligible)
    }
}
