//
//  FindBlueskyPostIntent.swift
//  Clip
//

import AppIntents
import Foundation

/// Finds a Bluesky post by search text (keyless public API) and saves the top
/// match to the reading list.
struct FindBlueskyPostIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Bluesky Post"
    static let description = IntentDescription(
        "Searches Bluesky for a post and saves the top match to your Click reading list.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Search", description: "Text to find the post — e.g. author + a phrase.")
    var query: String

    enum FindError: Error, CustomLocalizedStringResourceConvertible {
        case notFound
        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .notFound: return "Couldn't find a matching Bluesky post."
            }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = try? await BlueskySearchClient().topPostURL(query: trimmed)
        else { throw FindError.notFound }

        _ = await IntentIngestHelper.handleSavePressWithTimeout(urlString: url.absoluteString)
        return .result(value: ShareSuggestionStore.shared.pendingSuggestionToken())
    }
}
