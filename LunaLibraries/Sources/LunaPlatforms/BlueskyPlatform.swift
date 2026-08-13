//
//  BlueskyPlatform.swift
//  Luna
//

import LunaModels
import Foundation

/// Bluesky posts. No reliable app-open deep link (the `bluesky://` scheme is
/// compose-only) and posts aren't a 16:9 embed, so the launch ladder is just
/// Safari; oEmbed enriches the row with the post's title.
public struct BlueskyPlatform: PlatformModule {
    public let platform: ContentPlatform = .bluesky
    public let glyphSymbolName = "bubble.left.and.bubble.right.fill"

    public func appDeepLink(for item: SavedItem) -> URL? { nil }
    public func embed(for item: SavedItem) -> PlatformEmbed? { nil }

    public var metadataFetcher: PlatformMetadataFetching? { BlueskyMetadataFetcher() }
}

/// Best-effort metadata via Bluesky's keyless oEmbed. Nothing when oEmbed is
/// unavailable — the row still renders from its logo + link.
public struct BlueskyMetadataFetcher: PlatformMetadataFetching {
    private struct OEmbed: Decodable {
        let title: String?
    }

    public func fetchMetadata(for match: PlatformMatch, urlString: String) async -> PlatformMetadata? {
        guard var components = URLComponents(string: "https://embed.bsky.app/oembed") else {
            return nil
        }
        components.queryItems = [URLQueryItem(name: "url", value: urlString)]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let oembed = try? JSONDecoder().decode(OEmbed.self, from: data)
        else { return nil }

        return PlatformMetadata(title: oembed.title)
    }
}
