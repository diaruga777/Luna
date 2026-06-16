//
//  ShareSuggestionIntents.swift
//  Clip
//

import AppIntents
import Foundation

/// Returns the friend suggested for sharing by the most recent save (nil when
/// there is no suggestion). Used by the shortcut for the "Share with X?" prompt.
struct GetShareSuggestionIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Share Suggestion"
    static let description = IntentDescription(
        "After saving a link, returns the name of a friend you usually share such links with — or nothing.")
    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String?> {
        .result(value: ShareSuggestionStore.shared.pendingSuggestion()?.friendUsername)
    }
}

/// Returns the KIND of the pending share suggestion so the shortcut can offer
/// the right replies:
///   "none"      — no suggestion (do nothing).
///   "match"     — same-site/-channel history (replies: No / Just Once / Always).
///   "recommend" — content-similarity match (replies: No / Yes only).
struct GetShareSuggestionKindIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Share Suggestion Kind"
    static let description = IntentDescription(
        "Returns 'none', 'match', or 'recommend' for the current share suggestion.")
    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard let pending = ShareSuggestionStore.shared.pendingSuggestion() else {
            return .result(value: "none")
        }
        return .result(value: pending.isSemantic ? "recommend" : "match")
    }
}

/// Applies the user's answer to a share suggestion: "Don't Share" suppresses
/// it, "Share Once" sends now and keeps suggesting, "Always Share" sends now
/// and auto-shares that site to that friend from then on.
struct SetShareChoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Apply Share Choice"
    static let description = IntentDescription(
        "Responds to a share suggestion from Get Share Suggestion.")
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
                return "Couldn't send the article. It stays saved in Click."
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
