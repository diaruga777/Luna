//
//  PlatformModule.swift
//  Clip
//

import UIKit

/// The result of classifying a URL.
struct PlatformMatch: Equatable {
    let platform: ContentPlatform
    /// Platform item id (tweet id, post shortcode, video id, …), if extractable.
    let itemID: String?
    /// For music/podcast, which service the URL came from.
    let sourceService: MusicProvider?

    init(platform: ContentPlatform, itemID: String? = nil, sourceService: MusicProvider? = nil) {
        self.platform = platform
        self.itemID = itemID
        self.sourceService = sourceService
    }
}

/// An in-app embed for a platform item.
struct PlatformEmbed {
    let url: URL
    /// Referer header some embeds require (e.g. YouTube).
    let referer: String?
    /// JS injected at document end that posts "ended" so the host can mark read.
    let endedWatcherJS: String?

    init(url: URL, referer: String? = nil, endedWatcherJS: String? = nil) {
        self.url = url
        self.referer = referer
        self.endedWatcherJS = endedWatcherJS
    }
}

/// One platform's URL recognition + rendering behavior. Concrete per platform
/// (APIs/metadata diverge); the registry dispatches over them.
protocol PlatformModule {
    var platform: ContentPlatform { get }
    /// SF Symbol used as the row glyph / thumbnail fallback (until brand logos ship).
    var glyphSymbolName: String { get }

    /// Recognizes a URL as this platform, or nil.
    func classify(_ urlString: String) -> PlatformMatch?

    /// Subtitle line for the list row (creator/handle/artist), or nil.
    func subtitle(for item: ReadingListItem) -> String?

    /// Native-app deep link to open the item, or nil (→ embed/Safari).
    func appDeepLink(for item: ReadingListItem) -> URL?

    /// In-app embed for the item, or nil (→ Safari fallback).
    func embed(for item: ReadingListItem) -> PlatformEmbed?

    /// Optional best-effort metadata fetcher used at ingest. Default: none.
    var metadataFetcher: PlatformMetadataFetching? { get }
}

extension PlatformModule {
    var metadataFetcher: PlatformMetadataFetching? { nil }
}

/// Best-effort metadata for a platform item, fetched at ingest. Any field may be
/// nil — the item still renders from its logo + deep link.
struct PlatformMetadata {
    var title: String?
    var creator: String?
    var thumbnailData: Data?
    var mediaCreatorName: String?
    var mediaItemTitle: String?
}

/// Fetches best-effort metadata for a recognized platform item.
protocol PlatformMetadataFetching {
    func fetchMetadata(for match: PlatformMatch, urlString: String) async -> PlatformMetadata?
}
