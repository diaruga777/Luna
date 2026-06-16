//
//  PasteboardSuggester.swift
//  Clip
//

import Foundation

/// A pasteboard URL that has readable (article) or supported (YouTube) content,
/// surfaced as a one-tap "From Pasteboard" suggestion at the top of the reading
/// list. Not persisted until the user taps it.
struct PasteboardCandidate {
    let urlString: String
    let title: String
    let channelName: String?
    let videoID: String?
    /// Article content already extracted during the preview, so tapping can open
    /// the reader instantly without re-fetching. nil for videos/platform items.
    let content: ArticleContent?
    /// Set for a recognized non-YouTube platform URL (X, Bluesky, …).
    let platform: ContentPlatform?

    init(urlString: String, title: String, channelName: String?, videoID: String?,
         content: ArticleContent?, platform: ContentPlatform? = nil) {
        self.urlString = urlString
        self.title = title
        self.channelName = channelName
        self.videoID = videoID
        self.content = content
        self.platform = platform
    }

    var isVideo: Bool { videoID != nil }
}

protocol PasteboardSuggesting {
    /// Evaluates a pasteboard URL string: returns a candidate when it isn't
    /// already saved and something readable (an article) or supported (a
    /// YouTube video) can be extracted from it; nil otherwise.
    func evaluate(urlString: String) async -> PasteboardCandidate?
}

/// Default implementation: dedupes against the reading list, detects YouTube
/// links via oEmbed, and otherwise fetches + extracts the article to confirm
/// there's readable content.
final class PasteboardSuggester: PasteboardSuggesting {
    static let shared = PasteboardSuggester()

    private let store: ReadingListStore
    private let fetcher = ArticleFetcher()
    private let extractor = ArticleExtractor()
    private let youTubeMetadataFetcher: YouTubeMetadataFetching

    init(store: ReadingListStore = .shared,
         youTubeMetadataFetcher: YouTubeMetadataFetching = YouTubeOEmbedFetcher()) {
        self.store = store
        self.youTubeMetadataFetcher = youTubeMetadataFetcher
    }

    func evaluate(urlString: String) async -> PasteboardCandidate? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        // Already saved → nothing to suggest.
        guard store.item(forURLString: trimmed) == nil else { return nil }

        if let videoID = YouTubeURL.videoID(from: trimmed) {
            guard let metadata = try? await youTubeMetadataFetcher.fetchMetadata(videoID: videoID)
            else { return nil }
            return PasteboardCandidate(
                urlString: trimmed, title: metadata.title,
                channelName: metadata.channelName, videoID: videoID, content: nil)
        }

        // A recognized platform URL (tweet, skeet, …) surfaces as a platform
        // candidate (saved + ingested on tap; no article preview).
        if let match = PlatformRegistry.shared.detect(trimmed) {
            return PasteboardCandidate(
                urlString: trimmed, title: match.platform.displayName,
                channelName: nil, videoID: nil, content: nil, platform: match.platform)
        }

        guard let html = try? await fetcher.fetchHTML(from: url),
              let content = try? extractor.extract(html: html, baseURL: url),
              !content.blocks.isEmpty
        else { return nil }
        return PasteboardCandidate(
            urlString: trimmed, title: content.title,
            channelName: nil, videoID: nil, content: content)
    }
}
