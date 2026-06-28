//
//  YouTubePlatform.swift
//  Clip
//

import ClipURLClassification
import ClipModels
import UIKit

/// YouTube as a `PlatformModule`, wrapping the existing pure `YouTubeURL`. The
/// reading list still uses its bespoke thumbnail/open path for `.youtube` (no
/// behavior change); this entry centralizes classification and gives the new
/// platforms a worked example.
public struct YouTubePlatform: PlatformModule {
    public let platform: ContentPlatform = .youtube
    public let glyphSymbolName = "play.rectangle.fill"

    public func subtitle(for item: ReadingListItem) -> String? { item.channelName }

    public func appDeepLink(for item: ReadingListItem) -> URL? {
        guard let videoID = item.platformItemID ?? item.youtubeVideoID else { return nil }
        return YouTubeURL.appURL(videoID: videoID)
    }

    public func embed(for item: ReadingListItem) -> PlatformEmbed? {
        guard let videoID = item.platformItemID ?? item.youtubeVideoID,
              let content = NonTextualContent.detect(urlString: YouTubeURL.watchURLString(videoID: videoID)),
              let url = content.embedURL
        else { return nil }
        return PlatformEmbed(
            url: url, referer: content.embedReferer,
            endedWatcherJS: PlatformEmbedViewController.endedWatcherJS)
    }
}
