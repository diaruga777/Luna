//
//  PasteboardSuggester.swift
//  Clip
//

import ClipPlatforms
import ClipStorage
import ClipFetch
import ClipHTMLClassification
import ClipURLClassification
import ClipModels
import UIKit

/// A pasteboard URL that has readable (article) or supported (YouTube) content,
/// surfaced as a one-tap "From Pasteboard" suggestion at the top of the reading
/// list. Not persisted until the user taps Save. The preview also resolves a
/// thumbnail so the row looks like a normal saved row before it's saved.
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
    /// Best-effort preview thumbnail (cover art / video still / platform art).
    let thumbnail: UIImage?

    init(urlString: String, title: String, channelName: String?, videoID: String?,
         content: ArticleContent?, platform: ContentPlatform? = nil, thumbnail: UIImage? = nil) {
        self.urlString = urlString
        self.title = title
        self.channelName = channelName
        self.videoID = videoID
        self.content = content
        self.platform = platform
        self.thumbnail = thumbnail
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
        guard let url = URLUnwrapper.ingestURL(from: urlString) else { return nil }
        let normalizedURLString = url.absoluteString
        // Already saved → nothing to suggest. Match loosely (tracking params, www,
        // http/https, trailing slash) and by platform post id, since the pasteboard
        // copy of e.g. an X link often carries `?s=…` the saved one doesn't.
        guard !isAlreadySaved(normalizedURLString) else { return nil }

        if let videoID = YouTubeURL.videoID(from: normalizedURLString) {
            guard let metadata = try? await youTubeMetadataFetcher.fetchMetadata(videoID: videoID)
            else { return nil }
            let thumbnail = (try? await youTubeMetadataFetcher.fetchThumbnail(videoID: videoID))
                .flatMap { UIImage(data: $0) }
            return PasteboardCandidate(
                urlString: normalizedURLString, title: metadata.title,
                channelName: metadata.channelName, videoID: videoID, content: nil,
                thumbnail: thumbnail)
        }

        // A recognized platform URL (tweet, skeet, …) surfaces as a platform
        // candidate (saved + ingested on tap; no article preview).
        if let match = PlatformRegistry.shared.detect(normalizedURLString) {
            let art = await PlatformRegistry.shared.module(for: match.platform)?
                .metadataFetcher?.fetchMetadata(for: match, urlString: normalizedURLString)?
                .thumbnailData.flatMap { UIImage(data: $0) }
            return PasteboardCandidate(
                urlString: normalizedURLString, title: match.platform.displayName,
                channelName: nil, videoID: nil, content: nil, platform: match.platform,
                thumbnail: art)
        }

        guard let html = try? await fetcher.fetchHTML(from: url),
              let content = try? extractor.extract(html: html, baseURL: url),
              !content.blocks.isEmpty
        else { return nil }
        let cover = await coverImage(html: html, baseURL: url)
        return PasteboardCandidate(
            urlString: normalizedURLString, title: content.title,
            channelName: nil, videoID: nil, content: content, thumbnail: cover)
    }

    /// Whether `urlString` is already in the reading list, matching exactly, by
    /// platform post identity (same platform + item id, ignoring tracking params),
    /// or by a normalized host+path (ignoring scheme / www / query / trailing slash).
    private func isAlreadySaved(_ urlString: String) -> Bool {
        let items = store.items()
        if items.contains(where: { $0.urlString == urlString }) { return true }

        if let match = PlatformRecognizer.recognize(urlString), let id = match.itemID,
           items.contains(where: { $0.contentPlatform == match.platform && $0.platformItemID == id }) {
            return true
        }

        guard let key = Self.normalizedKey(urlString) else { return false }
        return items.contains { Self.normalizedKey($0.urlString) == key }
    }

    /// host (without `www.`) + path (without a trailing slash); ignores scheme,
    /// query, and fragment — so the same article/post matches across variants.
    private static func normalizedKey(_ urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              var host = components.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = components.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return host + path
    }

    /// Best-effort article cover image (og:image / twitter:image), short timeout.
    private func coverImage(html: String, baseURL: URL) async -> UIImage? {
        guard let imageURL = LeadImageExtractor.imageURL(in: html, baseURL: baseURL) else { return nil }
        var request = URLRequest(url: imageURL, timeoutInterval: 8)
        request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }
        return UIImage(data: data)
    }
}
