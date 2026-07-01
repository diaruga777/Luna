//
//  InstagramPlatform.swift
//  Luna
//

import LunaModels
import Foundation

/// Recognizes Instagram post/reel links: `instagram.com/(p|reel|reels|tv)/<shortcode>`.
public enum InstagramLink {
    private static let mediaSegments: Set<String> = ["p", "reel", "reels", "tv"]

    public static func isInstagram(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return host == "instagram.com" || host.hasSuffix(".instagram.com")
    }

    public static func shortcode(from urlString: String) -> String? {
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
public struct InstagramPlatform: PlatformModule {
    public let platform: ContentPlatform = .instagram
    public let glyphSymbolName = "camera.fill"

    public func subtitle(for item: ReadingListItem) -> String? { item.channelName }
    public func appDeepLink(for item: ReadingListItem) -> URL? { nil }
    public func embed(for item: ReadingListItem) -> PlatformEmbed? { nil }

    public var metadataFetcher: PlatformMetadataFetching? { OpenGraphMetadataFetcher() }
}
