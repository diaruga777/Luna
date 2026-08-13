//
//  SavePressPolicy.swift
//  Luna
//

import Foundation

/// Decides what a save press means. Pure logic so the full matrix is testable:
/// first press saves; a second press within the window triggers the configured
/// double-save behavior; everything else about an already-listed URL is ignored
/// until the user deletes and re-saves.
///
/// Two double-save regimes coexist:
/// - **Legacy (in-app saves)**: a second press within 12 s sends to every
///   ereader destination in double-save mode (skipping any sent in the past day).
/// - **Action Button (Save App Intent)**: when the caller passes an
///   `intentAction` (only the Action Button save path does), a second press
///   within 7 s performs that resolved action — the user's `DoubleSaveAction`
///   setting, already checked against what's configured. Passing `.doNothing`
///   (the default setting, or a Kindle that isn't set up) still selects this
///   regime, so an Action Button save NEVER falls back to the legacy one.
///   Contact actions are retained here as inert legacy cases.
public enum SavePressPolicy {

    public enum Decision: Equatable {
        /// URL not in the list — save and ingest it.
        case saveNew
        /// Double press detected — send the existing article to these ereader
        /// destinations (by id).
        case sendToEreaders(destinationIDs: [String])
        /// Double press detected — email the existing item to these friends.
        case sendToFriends(emails: [String])
        /// Double press detected — open the app's friend selector for the item.
        case promptFriendSelector
        /// Double press detected — build the existing article in this format and
        /// hand the file back as the App Intent's returned media.
        case exportArticle(format: ArticleExportFormat)
        /// Duplicate press — do nothing.
        case ignore
    }

    /// The configured Action Button double-save action, resolved by the caller
    /// (settings + configuration checks) so the policy itself stays pure.
    public enum IntentAction: Equatable {
        /// The user's setting is "Nothing", or the action they picked isn't
        /// usable (Kindle not configured). A repeat press is a no-op.
        case doNothing
        /// Send to Kindle (the caller verified Kindle is configured).
        case sendToKindle
        /// Return the article as a file in this format.
        case exportArticle(format: ArticleExportFormat)
        /// Email these preset friend addresses (caller verified non-empty).
        case sendToFriends(emails: [String])
        /// Open the friend selector in the app.
        case promptFriendSelector
    }

    /// Which double-save regime a press is governed by. The two regimes are
    /// mutually exclusive, so a caller picks exactly one — instead of setting
    /// an `intentAction: IntentAction?` alongside a `doubleSaveDestinationIDs:
    /// [String]` that the intent regime would silently ignore.
    public enum SavePressRegime: Equatable {
        /// Legacy in-app regime: a second press within `doublePressWindow`
        /// sends to every ereader destination in double-save mode.
        case inApp(doubleSaveDestinationIDs: [String])
        /// Action Button (Save App Intent) regime: a second press within
        /// `intentDoublePressWindow` performs the resolved action.
        case actionButton(IntentAction)
    }

    /// How close together two presses must be to count as a double save
    /// (legacy in-app regime).
    public static let doublePressWindow: TimeInterval = 12
    /// How close together two presses must be to count as an Action Button
    /// double save.
    public static let intentDoublePressWindow: TimeInterval = 7
    /// Articles sent within this interval aren't re-sent by a double press.
    public static let resendCooldown: TimeInterval = 24 * 60 * 60

    /// - Parameters:
    ///   - existingItem: the list item for this URL, nil if not saved yet.
    ///   - previousPressDate: when this URL was last saved/pressed (the item's
    ///     `dateAdded` if this is the first repeat press).
    ///   - regime: which double-save regime governs this press.
    public static func decide(
        existingItem: SavedItem?,
        previousPressDate: Date?,
        now: Date,
        regime: SavePressRegime
    ) -> Decision {
        guard let existingItem else { return .saveNew }

        switch regime {
        case .actionButton(let intentAction):
            let isDoublePress = previousPressDate.map {
                // There is deliberately NO minimum gap. Overlapping App Intent
                // runs may reserve the store in the opposite order from their
                // start dates, so compare absolute distance: zero and a small
                // negative interval are valid double saves too.
                abs(now.timeIntervalSince($0)) < intentDoublePressWindow
            } ?? false
            guard isDoublePress else { return .ignore }
            switch intentAction {
            case .doNothing:
                return .ignore
            case .exportArticle(let format):
                // Exports are built from stored article content, which platform
                // items (videos, posts, tracks) don't have.
                guard !existingItem.isPlatformItem else { return .ignore }
                return .exportArticle(format: format)
            case .sendToKindle:
                // Platform items (videos, posts, tracks) have no ereader EPUB
                // target — a Kindle double press on one is a no-op.
                guard !existingItem.isPlatformItem else { return .ignore }
                let eligible = eligibleDestinations(
                    [ArticleDestinationID.kindle], for: existingItem, now: now)
                return sendToEreadersOrIgnore(eligible)
            case .sendToFriends(let emails):
                // Friend shares email a link/content mail, so platform items work.
                return sendToFriendsOrIgnore(emails)
            case .promptFriendSelector:
                return .promptFriendSelector
            }

        case .inApp(let doubleSaveDestinationIDs):
            // Platform items (videos, posts, tracks) have no ereader EPUB
            // target — every repeat press is a no-op.
            guard !existingItem.isPlatformItem else { return .ignore }

            let isDoublePress = previousPressDate.map {
                abs(now.timeIntervalSince($0)) < doublePressWindow
            } ?? false
            guard isDoublePress else { return .ignore }

            let eligible = eligibleDestinations(doubleSaveDestinationIDs, for: existingItem, now: now)
            return sendToEreadersOrIgnore(eligible)
        }
    }

    /// Skips destinations already sent within the cooldown.
    private static func eligibleDestinations(
        _ destinationIDs: [String], for item: SavedItem, now: Date
    ) -> [String] {
        destinationIDs.filter { destinationID in
            let sentRecently = item.sendState(for: destinationID) == .sent
                && (item.dateSent(for: destinationID)
                    .map { now.timeIntervalSince($0) < resendCooldown } ?? false)
            return !sentRecently
        }
    }

    /// The shared `.isEmpty → .ignore` guard for all three destination lists —
    /// Kindle's eligible set, the legacy eligible set, and the friend-emails
    /// list — as two one-liners.
    private static func sendToEreadersOrIgnore(_ destinationIDs: [String]) -> Decision {
        destinationIDs.isEmpty ? .ignore : .sendToEreaders(destinationIDs: destinationIDs)
    }

    private static func sendToFriendsOrIgnore(_ emails: [String]) -> Decision {
        emails.isEmpty ? .ignore : .sendToFriends(emails: emails)
    }
}
