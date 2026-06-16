//
//  FindRedditPostIntent.swift
//  Clip
//

import AppIntents
import Foundation

/// Finds a Reddit post by search text (public search, no sign-in) and saves the
/// top match to the reading list.
struct FindRedditPostIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Reddit Post"
    static let description = IntentDescription(
        "Searches Reddit for a post and saves the top match to your Click reading list.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Search", description: "Text to find the post — e.g. subreddit + title.")
    var query: String

    enum FindError: Error, CustomLocalizedStringResourceConvertible {
        case notFound
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .notFound: return "Couldn't find a matching Reddit post."
            }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = try? await RedditSearchClient().topPostURL(query: trimmed)
        else { throw FindError.notFound }

        _ = await IntentIngestHelper.handleSavePressWithTimeout(urlString: url.absoluteString)
        return .result(value: ShareSuggestionStore.shared.pendingSuggestionToken())
    }
}
