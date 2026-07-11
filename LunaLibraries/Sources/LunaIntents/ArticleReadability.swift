//
//  ArticleReadability.swift
//  LunaIntents
//

import LunaModels
import Foundation

/// Which reading-list items are eligible to be Siri/Spotlight `ArticleEntity`
/// candidates (and to be selected/read by `ReadArticleIntent`) — deliberately
/// the SAME rule `AudioQueueRule.nextCandidate` (`Luna/AudioPlaybackWiring.swift`)
/// uses to decide what autoplay may queue: extraction finished (`.ready`, so
/// `.pending`/`.needsCaptcha` stubs are excluded) and the item renders in the
/// text reader rather than opening in a platform/media player or the
/// price-tracking screen. Never videos, social posts, or products.
public enum ArticleReadability {
    public static func isReadableArticle(_ item: ReadingListItem) -> Bool {
        item.state == .ready && item.contentPlatform == nil && !item.isPriceTracker
    }
}
