//
//  FindRedditPostIntent.swift
//  Clip
//

import AppIntents
import Foundation

/// Finds a specific Reddit post from precise fields — subreddit, optional author,
/// and the post title — via public search (no sign-in) and saves the top match.
struct FindRedditPostIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Reddit Post"
    static let description = IntentDescription(
        "Finds a Reddit post by subreddit + title (and optional author) and saves it to your Queue reading list.")
    static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Subreddit",
        description: "The community, with or without \"r/\" — e.g. \"r/swift\" or \"swift\".")
    var subreddit: String

    @Parameter(
        title: "Title",
        description: "The post's title (or a distinctive phrase from it).")
    var title: String

    @Parameter(
        title: "Author",
        description: "Optional poster username, with or without \"u/\".")
    var author: String?

    enum FindError: Error, CustomLocalizedStringResourceConvertible {
        case notFound
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .notFound: return "Couldn't find a matching Reddit post."
            }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let query = RedditPostQuery.searchQuery(subreddit: subreddit, title: title, author: author)
        guard !query.isEmpty, let url = try? await RedditSearchClient().topPostURL(query: query)
        else { throw FindError.notFound }

        _ = await IntentIngestHelper.handleSavePressWithTimeout(urlString: url.absoluteString)
        return .result(value: ShareSuggestionStore.shared.pendingSuggestionToken())
    }
}

/// Builds a Reddit search query from precise fields using Reddit's `subreddit:`
/// and `author:` operators. Pure, so the formatting is testable.
enum RedditPostQuery {
    static func searchQuery(subreddit: String, title: String, author: String?) -> String {
        let sub = subreddit.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "r/", with: "", options: [.anchored, .caseInsensitive])
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return "" }

        var parts = [cleanTitle]
        if !sub.isEmpty { parts.append("subreddit:\(sub)") }
        if let author {
            let user = author.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "u/", with: "", options: [.anchored, .caseInsensitive])
            if !user.isEmpty { parts.append("author:\(user)") }
        }
        return parts.joined(separator: " ")
    }
}
