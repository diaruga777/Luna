//
//  FindBlueskyPostIntent.swift
//  Lune
//
//  App Intent definition (app target, for discovery). Query building lives in
//  LuneIntents.BlueskyPostQuery; search in LunePlatforms.
//

import AppIntents
import LuneIntents
import LunePlatforms
import LuneSocial
import Foundation

struct FindBlueskyPostIntent: AppIntent {
    init() {}
    static let title: LocalizedStringResource = "Save Bluesky Post"
    static let description = IntentDescription(
        "Finds a Bluesky post by author handle + a phrase from it and saves it to your Lune reading list.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Handle", description: "The author's handle, with or without \"@\" — e.g. \"@jay.bsky.team\".")
    var handle: String

    @Parameter(title: "Text", description: "A distinctive phrase from the post's text.")
    var text: String

    enum FindError: Error, CustomLocalizedStringResourceConvertible {
        case notFound
        var localizedStringResource: LocalizedStringResource {
            switch self { case .notFound: return "Couldn't find a matching Bluesky post." }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let query = BlueskyPostQuery.searchQuery(handle: handle, text: text)
        guard !query.isEmpty, let url = try? await BlueskySearchClient().topPostURL(query: query)
        else { throw FindError.notFound }
        _ = await IntentIngestHelper.handleSavePressWithTimeout(urlString: url.absoluteString)
        return .result(value: ShareSuggestionStore.shared.pendingSuggestionToken())
    }
}
