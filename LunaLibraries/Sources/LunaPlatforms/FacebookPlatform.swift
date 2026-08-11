//
//  FacebookPlatform.swift
//  Luna
//

import LunaModels
import Foundation

/// Facebook videos/reels. Best-effort og: scrape, Safari open.
public struct FacebookPlatform: PlatformModule {
    public let platform: ContentPlatform = .facebook
    public let glyphSymbolName = "play.tv.fill"

    public func appDeepLink(for item: ReadingListItem) -> URL? { nil }
    public func embed(for item: ReadingListItem) -> PlatformEmbed? { nil }

    public var metadataFetcher: PlatformMetadataFetching? { OpenGraphMetadataFetcher() }
}

/// Shared og:-scrape metadata fetcher for platforms without a free API.
public struct OpenGraphMetadataFetcher: PlatformMetadataFetching {
    public func fetchMetadata(for match: PlatformMatch, urlString: String) async -> PlatformMetadata? {
        guard let og = await OpenGraphScraper.fetch(urlString: urlString) else { return nil }
        var thumbnailData: Data?
        if let imageURL = og.imageURL {
            thumbnailData = try? await URLSession.shared.data(from: imageURL).0
        }
        return PlatformMetadata(title: og.title, thumbnailData: thumbnailData)
    }
}
