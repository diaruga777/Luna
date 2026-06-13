//
//  ShareSuggestionIntents.swift
//  Clip
//

import AppIntents
import Foundation

/// Returns the friend suggested for sharing by the most recent save (nil when
/// there is no suggestion). The shortcut branches on this and shows a menu.
struct GetShareSuggestionIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Share Suggestion"
    static let description = IntentDescription(
        "After saving a link, returns the name of a friend you usually share such links with — or nothing.")
    static let openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ReturnsValue<String?> {
        .result(value: ShareSuggestionStore.shared.pendingSuggestion()?.friendUsername)
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

    @Parameter(title: "Choice", description: "Don't Share, Share Once, or Always Share.")
    var choice: String

    enum ChoiceError: Error, CustomLocalizedStringResourceConvertible {
        case unknownChoice
        case sendFailed

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .unknownChoice:
                return "Choice must be Don't Share, Share Once, or Always Share."
            case .sendFailed:
                return "Couldn't send the article. It stays saved in Clip."
            }
        }
    }

    func perform() async throws -> some IntentResult {
        guard let parsed = ShareSuggestionStore.Choice(rawValue: choice) else {
            throw ChoiceError.unknownChoice
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
