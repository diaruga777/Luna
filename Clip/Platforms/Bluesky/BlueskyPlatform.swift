//
//  BlueskyPlatform.swift
//  Clip
//

import Foundation

/// Bluesky posts. No reliable app-open deep link (the `bluesky://` scheme is
/// compose-only) and posts aren't a 16:9 embed, so the launch ladder is just
/// Safari; oEmbed enriches the row with the author handle.
struct BlueskyPlatform: PlatformModule {
    let platform: ContentPlatform = .bluesky
    let glyphSymbolName = "bubble.left.and.bubble.right.fill"

    func classify(_ urlString: String) -> PlatformMatch? {
        guard let post = BlueskyLink.post(from: urlString) else { return nil }
        return PlatformMatch(platform: .bluesky, itemID: post.rkey)
    }

    func subtitle(for item: ReadingListItem) -> String? { item.channelName }
    func appDeepLink(for item: ReadingListItem) -> URL? { nil }
    func embed(for item: ReadingListItem) -> PlatformEmbed? { nil }

    var metadataFetcher: PlatformMetadataFetching? { BlueskyMetadataFetcher() }
}

/// Best-effort metadata via Bluesky's keyless oEmbed; falls back to the handle
/// parsed from the URL when oEmbed is unavailable.
struct BlueskyMetadataFetcher: PlatformMetadataFetching {
    private struct OEmbed: Decodable {
        let author_name: String?
        let title: String?
    }

    func fetchMetadata(for match: PlatformMatch, urlString: String) async -> PlatformMetadata? {
        let handleFallback = BlueskyLink.post(from: urlString).map { "@\($0.author)" }

        guard var components = URLComponents(string: "https://embed.bsky.app/oembed") else {
            return PlatformMetadata(creator: handleFallback)
        }
        components.queryItems = [URLQueryItem(name: "url", value: urlString)]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let oembed = try? JSONDecoder().decode(OEmbed.self, from: data)
        else { return PlatformMetadata(creator: handleFallback) }

        return PlatformMetadata(
            title: oembed.title,
            creator: oembed.author_name ?? handleFallback)
    }
}
