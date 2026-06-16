//
//  YouTubePlatform.swift
//  Clip
//

import UIKit

/// YouTube as a `PlatformModule`, wrapping the existing pure `YouTubeURL`. The
/// reading list still uses its bespoke thumbnail/open path for `.youtube` (no
/// behavior change); this entry centralizes classification and gives the new
/// platforms a worked example.
struct YouTubePlatform: PlatformModule {
    let platform: ContentPlatform = .youtube
    let glyphSymbolName = "play.rectangle.fill"

    func classify(_ urlString: String) -> PlatformMatch? {
        guard let videoID = YouTubeURL.videoID(from: urlString) else { return nil }
        return PlatformMatch(platform: .youtube, itemID: videoID)
    }

    func subtitle(for item: ReadingListItem) -> String? { item.channelName }

    func appDeepLink(for item: ReadingListItem) -> URL? {
        guard let videoID = item.platformItemID ?? item.youtubeVideoID else { return nil }
        return YouTubeURL.appURL(videoID: videoID)
    }

    func embed(for item: ReadingListItem) -> PlatformEmbed? {
        guard let videoID = item.platformItemID ?? item.youtubeVideoID,
              let content = NonTextualContent.detect(urlString: YouTubeURL.watchURLString(videoID: videoID)),
              let url = content.embedURL
        else { return nil }
        return PlatformEmbed(
            url: url, referer: content.embedReferer,
            endedWatcherJS: PlatformEmbedViewController.endedWatcherJS)
    }
}
