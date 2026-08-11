//
//  InstagramPlatform.swift
//  Luna
//

import LunaModels
import Foundation

/// Instagram posts/reels. No reliable per-post app scheme and no free API →
/// best-effort og: scrape (often behind a login wall → logo fallback), Safari open.
public struct InstagramPlatform: PlatformModule {
    public let platform: ContentPlatform = .instagram
    public let glyphSymbolName = "camera.fill"

    public func appDeepLink(for item: ReadingListItem) -> URL? { nil }
    public func embed(for item: ReadingListItem) -> PlatformEmbed? { nil }

    public var metadataFetcher: PlatformMetadataFetching? { OpenGraphMetadataFetcher() }
}
