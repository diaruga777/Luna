//
//  PlatformModule.swift
//  Luna
//

import Foundation
import LunaModels

/// The result of classifying a URL.
public struct PlatformMatch: Equatable {
    public let platform: ContentPlatform
    /// Platform item id (tweet id, post shortcode, video id, …), if extractable.
    public let itemID: String?

    public init(platform: ContentPlatform, itemID: String? = nil) {
        self.platform = platform
        self.itemID = itemID
    }
}

/// An in-app embed for a platform item.
public struct PlatformEmbed {
    public let url: URL
    /// Referer header some embeds require.
    public let referer: String?
    /// JS injected at document end that posts "ended" so the host can mark read.
    public let endedWatcherJS: String?

    public init(url: URL, referer: String? = nil, endedWatcherJS: String? = nil) {
        self.url = url
        self.referer = referer
        self.endedWatcherJS = endedWatcherJS
    }
}

/// One platform's URL recognition + rendering behavior. Concrete per platform
/// (APIs/metadata diverge); the registry dispatches over them.
public protocol PlatformModule {
    var platform: ContentPlatform { get }
    /// SF Symbol used as the row glyph / thumbnail fallback (until brand logos ship).
    var glyphSymbolName: String { get }

    /// Native-app deep link to open the item, or nil (→ embed/Safari).
    func appDeepLink(for item: SavedItem) -> URL?

    /// In-app embed for the item, or nil (→ Safari fallback).
    func embed(for item: SavedItem) -> PlatformEmbed?

    /// Optional best-effort metadata fetcher used at ingest. Default: none.
    var metadataFetcher: PlatformMetadataFetching? { get }
}

public extension PlatformModule {
    var metadataFetcher: PlatformMetadataFetching? { nil }
}

/// Best-effort metadata for a platform item, fetched at ingest. Any field may be
/// nil — the item still renders from its logo + deep link.
public struct PlatformMetadata {
    public var title: String?
    public var thumbnailData: Data?

    public init(title: String? = nil, thumbnailData: Data? = nil) {
        self.title = title
        self.thumbnailData = thumbnailData
    }
}

/// Fetches best-effort metadata for a recognized platform item.
public protocol PlatformMetadataFetching {
    func fetchMetadata(for match: PlatformMatch, urlString: String) async -> PlatformMetadata?
}
