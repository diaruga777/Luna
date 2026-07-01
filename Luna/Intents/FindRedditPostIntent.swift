//
//  FindRedditPostIntent.swift
//  Luna
//
//  App Intent definition (app target, for discovery). Query building lives in
//  LunaIntents.RedditPostQuery; search in LunaPlatforms.
//

import AppIntents
import LunaIntents
import LunaPlatforms
import LunaSocial
import Foundation

struct FindRedditPostIntent: AppIntent {
    init() {}
    static let title: LocalizedStringResource = "Save Reddit Post"
    static let description = IntentDescription(
        "Finds a Reddit post by subreddit + title (and optional author) and saves it to your Luna reading list.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Subreddit", description: "The community, with or without \"r/\" — e.g. \"r/swift\" or \"swift\".")
    var subreddit: String

    @Parameter(title: "Title", description: "The post's title (or a distinctive phrase from it).")
    var title: String

    @Parameter(title: "Author", description: "Optional poster username, with or without \"u/\".")
    var author: String?

    enum FindError: Error, CustomLocalizedStringResourceConvertible {
        case notFound
        var localizedStringResource: LocalizedStringResource {
            switch self { case .notFound: return "Couldn't find a matching Reddit post." }
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
