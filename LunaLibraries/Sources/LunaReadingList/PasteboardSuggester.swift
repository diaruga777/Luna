//
//  PasteboardSuggester.swift
//  Luna
//

import LunaStorage
import LunaFetch
import LunaHTMLClassification
import LunaIngest
import LunaURLClassification
import LunaModels
import UIKit

/// A pasteboard URL that has readable or supported content,
/// surfaced as a one-tap "From Pasteboard" suggestion at the top of the reading
/// list. Not persisted until the user taps Save. The preview also resolves a
/// thumbnail so the row looks like a normal saved row before it's saved.
public struct PasteboardCandidate {
    public let urlString: String
    public let title: String
    public let channelName: String?
    /// Article content already extracted during the preview, so tapping can open
    /// the reader instantly without re-fetching. nil for videos/platform items.
    public let content: ArticleContent?
    /// Set for a recognized platform URL.
    public let platform: ContentPlatform?
    /// True when the URL is a paywalled article that must go through the normal
    /// saved-item WKWebView unlock flow before any reader preview exists.
    public let requiresUnlock: Bool
    /// Best-effort preview thumbnail.
    public let thumbnail: UIImage?

    public init(urlString: String, title: String, channelName: String?,
         content: ArticleContent?, platform: ContentPlatform? = nil,
         requiresUnlock: Bool = false, thumbnail: UIImage? = nil) {
        self.urlString = urlString
        self.title = title
        self.channelName = channelName
        self.content = content
        self.platform = platform
        self.requiresUnlock = requiresUnlock
        self.thumbnail = thumbnail
    }
}

/// Dedupes against the reading list and confirms there is readable content or
/// a recognized platform item.
public final class PasteboardSuggester {
    public static let shared = PasteboardSuggester()

    /// Best-effort preview art for a recognized platform URL, installed by the
    /// media-handling apps' `KindWiring` (it needs `PlatformRegistry`'s metadata
    /// fetchers, which LunaReadingList must not depend on). nil ⇒ no art; the
    /// platform CANDIDATE is still produced — recognition itself is URL-only
    /// (`PlatformRecognizer`) — and the shell's per-surface filter
    /// (`surfaceAllows`) drops foreign-kind candidates as before.
    public static var platformPreviewArt:
        ((_ platform: ContentPlatform, _ itemID: String?, _ urlString: String) async -> UIImage?)?

    private let store: ReadingListStore
    private let fetcher: HTMLFetching

    public init(store: ReadingListStore = .shared,
         fetcher: HTMLFetching = ArticleFetcher()) {
        self.store = store
        self.fetcher = fetcher
    }

    public func evaluate(urlString: String) async -> PasteboardCandidate? {
        guard let url = URLUnwrapper.ingestURL(from: urlString) else { return nil }
        let normalizedURLString = url.absoluteString
        // Already saved → nothing to suggest. Match loosely (tracking params, www,
        // http/https, trailing slash) and by platform post id, since the pasteboard
        // copy of e.g. an X link often carries `?s=…` the saved one doesn't.
        guard !isAlreadySaved(normalizedURLString) else { return nil }

        // A recognized platform URL surfaces as a platform
        // candidate (saved + ingested on tap; no article preview).
        if let match = PlatformRecognizer.recognize(normalizedURLString) {
            let art = await Self.platformPreviewArt?(
                match.platform, match.itemID, normalizedURLString)
            return PasteboardCandidate(
                urlString: normalizedURLString, title: match.platform.displayName,
                channelName: nil, content: nil, platform: match.platform,
                thumbnail: art)
        }

        guard let html = try? await fetcher.fetchHTML(from: url) else { return nil }
        let outcome = await IngestPipeline.process(
            IngestInput(url: url, source: .paste, prefetchedHTML: html),
            fetcher: fetcher)
        switch outcome {
        case let .article(content, _):
            guard !content.blocks.isEmpty else { return nil }
            let cover = await coverImage(html: html, baseURL: url)
            // Eagerly preload this clipboard candidate's linked pages (text + images) so an
            // open/save is instant offline. Bounded to the current clipboard link and
            // Wi-Fi-gated; harmlessly re-triggered (deduped) if the same URL is re-evaluated.
            // Routed through the article handler (`PreloadCoordinator` is article-kind).
            IngestorKindHandlers.article?.preloadPasteboard(content: content, sourceURL: url)
            return PasteboardCandidate(
                urlString: normalizedURLString, title: content.title,
                channelName: nil, content: content, thumbnail: cover)
        case let .needsArchive(title):
            let fallbackTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let cover = await coverImage(html: html, baseURL: url)
            return PasteboardCandidate(
                urlString: normalizedURLString,
                title: fallbackTitle.isEmpty ? normalizedURLString : fallbackTitle,
                channelName: nil, content: nil,
                requiresUnlock: true, thumbnail: cover)
        default:
            return nil
        }
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
              let host = components.host else { return nil }
        return HostMatching.normalizedHost(host) + HostMatching.normalizedPath(components.path)
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
