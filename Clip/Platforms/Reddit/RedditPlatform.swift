//
//  RedditPlatform.swift
//  Clip
//

import Foundation

/// Recognizes Reddit post links: `reddit.com/r/<sub>/comments/<id>/<slug>`. Pure.
enum RedditLink {
    static func isReddit(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return host == "reddit.com" || host.hasSuffix(".reddit.com") || host == "redd.it"
    }

    /// The base-36 post id from a `/comments/<id>/…` permalink.
    static func postID(from urlString: String) -> String? {
        guard let url = URL(string: urlString), isReddit(urlString) else { return nil }
        let segments = Array(url.pathComponents.dropFirst())
        guard let commentsIndex = segments.firstIndex(of: "comments"),
              commentsIndex + 1 < segments.count else { return nil }
        let id = segments[commentsIndex + 1]
        return id.isEmpty ? nil : id
    }

    /// The public JSON metadata URL for a permalink.
    static func jsonURL(for urlString: String) -> URL? {
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
struct RedditPlatform: PlatformModule {
    let platform: ContentPlatform = .reddit
    let glyphSymbolName = "bubble.left.and.text.bubble.right.fill"

    func classify(_ urlString: String) -> PlatformMatch? {
        guard RedditLink.isReddit(urlString) else { return nil }
        return PlatformMatch(platform: .reddit, itemID: RedditLink.postID(from: urlString))
    }

    func subtitle(for item: ReadingListItem) -> String? { item.channelName }
    func appDeepLink(for item: ReadingListItem) -> URL? { nil }
    func embed(for item: ReadingListItem) -> PlatformEmbed? { nil }

    var metadataFetcher: PlatformMetadataFetching? { RedditMetadataFetcher() }
}

/// Public Reddit listing JSON (`<permalink>.json`) → title + subreddit.
struct RedditMetadataFetcher: PlatformMetadataFetching {
    func fetchMetadata(for match: PlatformMatch, urlString: String) async -> PlatformMetadata? {
        guard let url = RedditLink.jsonURL(for: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue("Click/1.0 (reading list)", forHTTPHeaderField: "User-Agent")
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
        return PlatformMetadata(title: title, creator: subreddit)
    }
}
