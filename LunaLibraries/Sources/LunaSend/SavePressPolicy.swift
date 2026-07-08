//
//  SavePressPolicy.swift
//  Luna
//

import LunaModels
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
///   within 7 s performs the user's configured double-save action instead —
///   send to Kindle, email preset friends, or open the friend selector.
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
        /// Duplicate press — do nothing.
        case ignore
    }

    /// The configured Action Button double-save action, resolved by the caller
    /// (settings + configuration checks) so the policy itself stays pure.
    public enum IntentAction: Equatable {
        /// Send to Kindle (the caller verified Kindle is configured).
        case sendToKindle
        /// Email these preset friend addresses (caller verified non-empty).
        case sendToFriends(emails: [String])
        /// Open the friend selector in the app.
        case promptFriendSelector
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
    ///   - doubleSaveDestinationIDs: destinations that are configured AND in
    ///     double-save mode right now (legacy regime).
    ///   - intentAction: the resolved Action Button double-save action; non-nil
    ///     ONLY for saves arriving through the Action Button's Save App Intent,
    ///     which switches this press into the 7 s intent regime.
    public static func decide(
        existingItem: ReadingListItem?,
        previousPressDate: Date?,
        now: Date,
        doubleSaveDestinationIDs: [String],
        intentAction: IntentAction? = nil
    ) -> Decision {
        guard let existingItem else { return .saveNew }

        if let intentAction {
            let isDoublePress = previousPressDate.map {
                now.timeIntervalSince($0) < intentDoublePressWindow
            } ?? false
            guard isDoublePress else { return .ignore }
            switch intentAction {
            case .sendToKindle:
                // Platform items (videos, posts, tracks) have no ereader EPUB
                // target — a Kindle double press on one is a no-op.
                guard !existingItem.isPlatformItem else { return .ignore }
                let eligible = eligibleDestinations(
                    [ArticleDestinationID.kindle], for: existingItem, now: now)
                return eligible.isEmpty ? .ignore : .sendToEreaders(destinationIDs: eligible)
            case .sendToFriends(let emails):
                // Friend shares email a link/content mail, so platform items work.
                return emails.isEmpty ? .ignore : .sendToFriends(emails: emails)
            case .promptFriendSelector:
                return .promptFriendSelector
            }
        }

        // Platform items (videos, posts, tracks) have no ereader EPUB target —
        // every repeat press is a no-op.
        guard !existingItem.isPlatformItem else { return .ignore }

        let isDoublePress = previousPressDate.map {
            now.timeIntervalSince($0) < doublePressWindow
        } ?? false
        guard isDoublePress, !doubleSaveDestinationIDs.isEmpty else { return .ignore }

        let eligible = eligibleDestinations(doubleSaveDestinationIDs, for: existingItem, now: now)
        return eligible.isEmpty ? .ignore : .sendToEreaders(destinationIDs: eligible)
    }

    /// Skips destinations already sent within the cooldown.
    private static func eligibleDestinations(
        _ destinationIDs: [String], for item: ReadingListItem, now: Date
    ) -> [String] {
        destinationIDs.filter { destinationID in
            let sentRecently = item.sendState(for: destinationID) == .sent
                && (item.dateSent(for: destinationID)
                    .map { now.timeIntervalSince($0) < resendCooldown } ?? false)
            return !sentRecently
        }
    }
}
