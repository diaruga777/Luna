//
//  SavePressPolicy.swift
//  Clip
//

import Foundation

/// Decides what a save press means. Pure logic so the full matrix is testable:
/// first press saves; a second press within the window sends to Kindle (when
/// configured and not already sent in the past day); everything else about an
/// already-listed URL is ignored until the user deletes it and saves again.
enum SavePressPolicy {

    enum Decision: Equatable {
        /// URL not in the list — save and ingest it.
        case saveNew
        /// Double press detected — send the existing article to Kindle.
        case sendToKindle
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
    static func decide(
        existingItem: ReadingListItem?,
        previousPressDate: Date?,
        now: Date,
        sendMode: KindleSendSettings.SendMode,
        kindleConfigured: Bool
    ) -> Decision {
        guard let existingItem else { return .saveNew }

        let isDoublePress = previousPressDate.map {
            now.timeIntervalSince($0) < doublePressWindow
        } ?? false
        guard isDoublePress, sendMode == .doubleSave, kindleConfigured else {
            return .ignore
        }

        let sentRecently = existingItem.sendState == .sent
            && existingItem.dateSent.map { now.timeIntervalSince($0) < resendCooldown } ?? false
        return sentRecently ? .ignore : .sendToKindle
    }
}
