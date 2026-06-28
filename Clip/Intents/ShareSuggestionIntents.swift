//
//  ShareSuggestionIntents.swift
//  Clip
//

import ClipSocial
import ClipStorage
import AppIntents
import Foundation

// NOTE: the former GetShareSuggestionIntent / GetShareSuggestionKindIntent were
// removed — the save intents (ClipSafariPageIntent, FindYouTubeVideoIntent) now
// return the share-suggestion token directly (see ShareSuggestionStore.
// pendingSuggestionToken), so the shortcut needs only the save action + this.

/// Applies the user's answer to a share suggestion: "Don't Share" suppresses
/// it, "Share Once" sends now and keeps suggesting, "Always Share" sends now
/// and auto-shares that site to that friend from then on.
struct SetShareChoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Share Choice"
    static let description = IntentDescription(
        "Responds to the share suggestion returned when you save a page or video.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Choice",
               description: "Don't Share, Share Once, Always Share, No, or Yes.")
    var choice: String

    enum ChoiceError: Error, CustomLocalizedStringResourceConvertible {
        case unknownChoice
        case sendFailed

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .unknownChoice:
                return "Choice must be Don't Share, Share Once, Always Share, No, or Yes."
            case .sendFailed:
                return "Couldn't send the article. It stays saved in Queue."
            }
        }
    }

    func perform() async throws -> some IntentResult {
        // "No"/"Yes" are the two-option replies for a content recommendation;
        // map them onto the underlying choices (Yes = share once).
        let parsed: ShareSuggestionStore.Choice
        switch choice {
        case "No": parsed = .dontShare
        case "Yes": parsed = .shareOnce
        default:
            guard let known = ShareSuggestionStore.Choice(rawValue: choice) else {
                throw ChoiceError.unknownChoice
            }
            parsed = known
        }
        guard let suggestion = ShareSuggestionStore.shared.applyChoice(parsed) else {
            return .result() // nothing pending — stale shortcut run
        }
        guard parsed != .dontShare else { return .result() }

        guard let friend = FriendsStore.shared.friend(withUUID: suggestion.friendUUID) else {
            return .result() // friend was deleted since the suggestion armed
        }
        do {
            // "Share Once" feeds the streak (counts as a manual share);
            // the first "Always Share" send doesn't need to.
            try await SocialMessageCenter.shared.sendArticle(
                urlString: suggestion.urlString,
                title: ReadingListStore.shared.item(forURLString: suggestion.urlString)?.title,
                to: friend,
                countsAsManualShare: parsed == .shareOnce)
        } catch {
            throw ChoiceError.sendFailed
        }
        return .result()
    }
}
