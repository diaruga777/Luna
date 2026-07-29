//
//  XPostIngestProcessor.swift
//  LunaArticleIngest
//

import LunaIngest
import LunaModels
import Foundation

/// The social-text pipeline processor: turns a long-form X post (or an unrolled
/// self-thread) into a readable article, and declines everything else.
///
/// Registered into `IngestKindProcessors.socialText` by article-handling targets'
/// composition roots (the central Luna app + Reader). The Downloader and Price
/// Tracker link no article module, register nothing, and so keep today's behavior
/// exactly: every X link stays `.social` and is handled (or dropped) as before.
///
/// ## Why this is an API call and not HTML extraction
///
/// X serves an unauthenticated client a JavaScript login shell — the post text is
/// simply not in the HTML — so the ordinary fetch/extract/bypass tiers can never
/// read one. The keyless fxtwitter mirror is the same source the existing
/// `XMetadataFetcher` and `SocialMediaResolver` already read for X metadata and
/// media; this asks it for the post's text instead.
public final class XPostIngestProcessor: SocialTextIngestProcessing {
    /// Injectable so tests exercise the whole processor from fixtures with no
    /// network. Production uses the fxtwitter fetch below.
    private let fetch: (String) async -> Data?

    public init(fetch: ((String) async -> Data?)? = nil) {
        self.fetch = fetch ?? XPostIngestProcessor.fetchFromAPI
    }

    /// Total budget for the (at most two) API calls. Comfortably inside the
    /// pipeline's own 28s ceiling, so a slow mirror surfaces as "not readable"
    /// (the post still saves as a social item) rather than eating the whole call.
    static let requestTimeout: TimeInterval = 10

    public func article(
        platform: ContentPlatform, itemID: String?, url: URL
    ) async -> SocialTextArticle? {
        // Only X, and only a post with an id — a bare profile URL has no text.
        guard platform == .x, let itemID, !itemID.isEmpty,
              itemID.allSatisfy(\.isNumber) else { return nil }

        // The v2 thread route first: it unrolls a self-thread from ANY member, so
        // one call covers both the single-post and chained-thread cases. The v1
        // single-post route is the fallback if v2 is unavailable.
        for endpoint in [
            "https://api.fxtwitter.com/2/thread/\(itemID)",
            "https://api.fxtwitter.com/status/\(itemID)",
        ] {
            guard let data = await fetch(endpoint),
                  let payload = try? JSONDecoder().decode(XPostPayload.self, from: data),
                  !payload.posts.isEmpty else { continue }
            if let content = XPostExtractor.article(from: payload, url: url) {
                return SocialTextArticle(
                    content: content, html: XPostHTMLRenderer.html(for: content, url: url))
            }
            // A well-formed payload that is simply too short is a definitive "no" —
            // the fallback endpoint would return the same post. Stop here so a short
            // post costs one request, not two.
            return nil
        }
        return nil
    }

    /// The production fetch: a plain keyless GET, 2xx only.
    private static func fetchFromAPI(_ endpoint: String) async -> Data? {
        guard let url = URL(string: endpoint) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        // The mirror varies its response by client; ask for JSON explicitly.
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return data
    }
}
