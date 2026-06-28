//
//  FindBlueskyPostIntent.swift
//  Clip
//

import ClipSocial
import ClipPlatforms
import AppIntents
import Foundation

/// Finds a Bluesky post from the author handle + a phrase from the post (keyless
/// public search) and saves the top match to the reading list.
public struct FindBlueskyPostIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Save Bluesky Post"
    public static let description = IntentDescription(
        "Finds a Bluesky post by author handle + a phrase from it and saves it to your Queue reading list.")
    public static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Handle",
        description: "The author's handle, with or without \"@\" — e.g. \"@jay.bsky.team\".")
    public var handle: String

    @Parameter(
        title: "Text",
        description: "A distinctive phrase from the post's text.")
    public var text: String

    public enum FindError: Error, CustomLocalizedStringResourceConvertible {
        case notFound
        public var localizedStringResource: LocalizedStringResource {
            switch self {
            case .notFound: return "Couldn't find a matching Bluesky post."
            }
        }
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let query = BlueskyPostQuery.searchQuery(handle: handle, text: text)
        guard !query.isEmpty, let url = try? await BlueskySearchClient().topPostURL(query: query)
        else { throw FindError.notFound }

        _ = await IntentIngestHelper.handleSavePressWithTimeout(urlString: url.absoluteString)
        return .result(value: ShareSuggestionStore.shared.pendingSuggestionToken())
    }
}

/// Builds a Bluesky search query from the handle + text using the `from:`
/// operator. Pure, so the formatting is testable.
public enum BlueskyPostQuery {
    public static func searchQuery(handle: String, text: String) -> String {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "", options: [.anchored])
        var parts: [String] = []
        if !cleanText.isEmpty { parts.append(cleanText) }
        if !cleanHandle.isEmpty { parts.append("from:\(cleanHandle)") }
        return parts.joined(separator: " ")
    }
}
