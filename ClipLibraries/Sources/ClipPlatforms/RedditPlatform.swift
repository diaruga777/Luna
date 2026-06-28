//
//  RedditPlatform.swift
//  Clip
//

import ClipFetch
import ClipModels
import Foundation

/// Recognizes Reddit post links: `reddit.com/r/<sub>/comments/<id>/<slug>`. Pure.
public enum RedditLink {
    public static func isReddit(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return host == "reddit.com" || host.hasSuffix(".reddit.com") || host == "redd.it"
    }

    /// The subreddit ("r/<name>") from a permalink path, if present.
    public static func subreddit(from urlString: String) -> String? {
        guard let url = URL(string: urlString) else { return nil }
        let segments = Array(url.pathComponents.dropFirst())
        guard let index = segments.firstIndex(where: { $0.lowercased() == "r" }),
              index + 1 < segments.count, !segments[index + 1].isEmpty else { return nil }
        return "r/\(segments[index + 1])"
    }

    /// The base-36 post id from a `/comments/<id>/…` permalink.
    public static func postID(from urlString: String) -> String? {
        guard let url = URL(string: urlString), isReddit(urlString) else { return nil }
        let segments = Array(url.pathComponents.dropFirst())
        guard let commentsIndex = segments.firstIndex(of: "comments"),
              commentsIndex + 1 < segments.count else { return nil }
        let id = segments[commentsIndex + 1]
        return id.isEmpty ? nil : id
    }

    /// The public JSON metadata URL for a permalink.
    public static func jsonURL(for urlString: String) -> URL? {
        guard var components = URLComponents(string: urlString) else { return nil }
        // Strip any trailing slash, append .json.
        var path = components.path
        if path.hasSuffix("/") { path.removeLast() }
        components.path = path + ".json"
        components.query = nil
        return components.url
    }
}

/// Reddit posts. Opens in Safari (Reddit's universal links hand off to the app
/// when installed); public `.json` supplies title + subreddit.
public struct RedditPlatform: PlatformModule {
    public let platform: ContentPlatform = .reddit
    public let glyphSymbolName = "bubble.left.and.text.bubble.right.fill"

    public func subtitle(for item: ReadingListItem) -> String? {
        item.channelName ?? RedditLink.subreddit(from: item.urlString)
    }
    public func appDeepLink(for item: ReadingListItem) -> URL? { nil }
    public func embed(for item: ReadingListItem) -> PlatformEmbed? { nil }

    public var metadataFetcher: PlatformMetadataFetching? { RedditMetadataFetcher() }
}

/// Public Reddit listing JSON (`<permalink>.json`) → title + subreddit.
public struct RedditMetadataFetcher: PlatformMetadataFetching {
    public func fetchMetadata(for match: PlatformMatch, urlString: String) async -> PlatformMetadata? {
        guard let url = RedditLink.jsonURL(for: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
        else { return nil }

        // [{ data: { children: [{ data: { title, subreddit_name_prefixed } }] } }, …]
        guard let listings = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let first = listings.first as? [String: Any],
              let listing = first["data"] as? [String: Any],
              let children = listing["children"] as? [[String: Any]],
              let postData = children.first?["data"] as? [String: Any]
        else { return nil }

        let title = postData["title"] as? String
        let subreddit = postData["subreddit_name_prefixed"] as? String
            ?? (postData["subreddit"] as? String).map { "r/\($0)" }

        var thumbnailData: Data?
        if let imageURL = Self.bestImageURL(in: postData) {
            thumbnailData = try? await URLSession.shared.data(from: imageURL).0
        }
        return PlatformMetadata(title: title, creator: subreddit, thumbnailData: thumbnailData)
    }

    /// Reddit posts hide their image in several shapes depending on type — a
    /// single image, a gallery, a direct `i.redd.it` link, a crosspost, or just a
    /// thumbnail. Tries them in quality order. Reddit JSON HTML-escapes `&`.
    private static func bestImageURL(in postData: [String: Any]) -> URL? {
        func clean(_ s: String) -> URL? {
            URL(string: s.replacingOccurrences(of: "&amp;", with: "&"))
        }

        // 1. preview.images[0].source (largest single-image preview).
        if let preview = postData["preview"] as? [String: Any],
           let images = preview["images"] as? [[String: Any]],
           let source = images.first?["source"] as? [String: Any],
           let url = source["url"] as? String, let result = clean(url) {
            return result
        }
        // 2. Gallery: media_metadata holds {id: {s: {u: <url>}}} (or p[] previews).
        if let media = postData["media_metadata"] as? [String: Any] {
            // Honor gallery order when present, else any entry.
            let orderedIDs = (postData["gallery_data"] as? [String: Any])
                .flatMap { $0["items"] as? [[String: Any]] }?
                .compactMap { $0["media_id"] as? String } ?? Array(media.keys)
            for id in orderedIDs {
                guard let entry = media[id] as? [String: Any] else { continue }
                if let s = entry["s"] as? [String: Any],
                   let u = (s["u"] ?? s["gif"]) as? String, let result = clean(u) {
                    return result
                }
            }
        }
        // 3. Direct image link (i.redd.it or any image-extension URL).
        if let direct = (postData["url_overridden_by_dest"] ?? postData["url"]) as? String,
           Self.looksLikeImage(direct), let result = clean(direct) {
            return result
        }
        // 4. Crosspost parent's preview.
        if let parents = postData["crosspost_parent_list"] as? [[String: Any]],
           let parent = parents.first, let nested = bestImageURL(in: parent) {
            return nested
        }
        // 5. A usable thumbnail (skip reddit's "self"/"default"/"nsfw" sentinels).
        if let thumb = postData["thumbnail"] as? String, thumb.hasPrefix("http"),
           let result = clean(thumb) {
            return result
        }
        return nil
    }

    private static func looksLikeImage(_ urlString: String) -> Bool {
        let lower = urlString.lowercased()
        if let host = URL(string: urlString)?.host?.lowercased(),
           host == "i.redd.it" || host == "i.imgur.com" { return true }
        return [".jpg", ".jpeg", ".png", ".webp", ".gif"].contains { lower.contains($0) }
    }
}
