//
//  InstagramPlatform.swift
//  Clip
//

import Foundation

/// Recognizes Instagram post/reel links: `instagram.com/(p|reel|reels|tv)/<shortcode>`.
enum InstagramLink {
    private static let mediaSegments: Set<String> = ["p", "reel", "reels", "tv"]

    static func isInstagram(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return host == "instagram.com" || host.hasSuffix(".instagram.com")
    }

    static func shortcode(from urlString: String) -> String? {
        guard let url = URL(string: urlString), isInstagram(urlString) else { return nil }
        let segments = Array(url.pathComponents.dropFirst())
        guard let kindIndex = segments.firstIndex(where: { mediaSegments.contains($0) }),
              kindIndex + 1 < segments.count else { return nil }
        let code = segments[kindIndex + 1]
        return code.isEmpty ? nil : code
    }
}

/// Instagram posts/reels. No reliable per-post app scheme and no free API →
/// best-effort og: scrape (often behind a login wall → logo fallback), Safari open.
struct InstagramPlatform: PlatformModule {
    let platform: ContentPlatform = .instagram
    let glyphSymbolName = "camera.fill"

    func subtitle(for item: ReadingListItem) -> String? { item.channelName }
    func appDeepLink(for item: ReadingListItem) -> URL? { nil }
    func embed(for item: ReadingListItem) -> PlatformEmbed? { nil }

    var metadataFetcher: PlatformMetadataFetching? { OpenGraphMetadataFetcher() }
}
