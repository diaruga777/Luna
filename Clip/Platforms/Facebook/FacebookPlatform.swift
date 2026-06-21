//
//  FacebookPlatform.swift
//  Clip
//

import Foundation

/// Recognizes Facebook links: `facebook.com/…/videos/<id>`, `/reel/<id>`,
/// `/watch/?v=<id>`, and `fb.watch/<code>`. URLs are messy — when the id can't
/// be pinned down it's left nil (the URL still opens).
enum FacebookLink {
    static func isFacebook(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return host == "facebook.com" || host.hasSuffix(".facebook.com")
            || host == "fb.watch" || host == "fb.com"
    }

    static func itemID(from urlString: String) -> String? {
        guard let url = URL(string: urlString), isFacebook(urlString) else { return nil }
        if let v = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v
        }
        let segments = Array(url.pathComponents.dropFirst())
        if let reelIndex = segments.firstIndex(of: "reel"), reelIndex + 1 < segments.count {
            return segments[reelIndex + 1]
        }
        if let videosIndex = segments.firstIndex(of: "videos"), videosIndex + 1 < segments.count {
            return segments[videosIndex + 1]
        }
        return nil
    }
}

/// Facebook videos/reels. Best-effort og: scrape, Safari open.
struct FacebookPlatform: PlatformModule {
    let platform: ContentPlatform = .facebook
    let glyphSymbolName = "play.tv.fill"

    func subtitle(for item: ReadingListItem) -> String? { item.channelName }
    func appDeepLink(for item: ReadingListItem) -> URL? { nil }
    func embed(for item: ReadingListItem) -> PlatformEmbed? { nil }

    var metadataFetcher: PlatformMetadataFetching? { OpenGraphMetadataFetcher() }
}

/// Shared og:-scrape metadata fetcher for platforms without a free API.
struct OpenGraphMetadataFetcher: PlatformMetadataFetching {
    func fetchMetadata(for match: PlatformMatch, urlString: String) async -> PlatformMetadata? {
        guard let og = await OpenGraphScraper.fetch(urlString: urlString) else { return nil }
        var thumbnailData: Data?
        if let imageURL = og.imageURL {
            thumbnailData = try? await URLSession.shared.data(from: imageURL).0
        }
        return PlatformMetadata(title: og.title, creator: nil, thumbnailData: thumbnailData)
    }
}
