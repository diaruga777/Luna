//
//  SocialPostFinder.swift
//  Clip
//

import Foundation

/// Finds a specific social post's URL for platforms with no public search API
/// (X, TikTok, Instagram, Facebook), from the author handle plus a content
/// snippet and/or timestamp, via a keyless DuckDuckGo HTML search. Best-effort:
/// returns nil when nothing convincingly matches.
enum SocialPostFinder {

    enum Platform {
        case x, tiktok, instagram, facebook

        /// Hosts that count as this platform.
        var hosts: [String] {
            switch self {
            case .x: return ["x.com", "twitter.com", "mobile.twitter.com"]
            case .tiktok: return ["tiktok.com", "vm.tiktok.com"]
            case .instagram: return ["instagram.com"]
            case .facebook: return ["facebook.com", "fb.watch", "m.facebook.com"]
            }
        }

        /// Path fragments that mark a real post (vs. a profile/home page).
        var postMarkers: [String] {
            switch self {
            case .x: return ["/status/"]
            case .tiktok: return ["/video/", "/photo/"]
            case .instagram: return ["/p/", "/reel/", "/tv/"]
            case .facebook: return ["/posts/", "/videos/", "/watch", "/permalink", "/story", "/reel/"]
            }
        }

        /// The host used to scope the search.
        var searchDomain: String {
            switch self {
            case .x: return "x.com"
            case .tiktok: return "tiktok.com"
            case .instagram: return "instagram.com"
            case .facebook: return "facebook.com"
            }
        }
    }

    /// - Parameters:
    ///   - handle: author handle (with or without a leading @).
    ///   - content: a phrase / prefix from the post (optional).
    ///   - timestamp: a date/time string shown on the post (optional).
    static func findPostURL(
        platform: Platform, handle: String, content: String?, timestamp: String?
    ) async -> URL? {
        let cleanHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "", options: [.anchored])
        let snippet = [content, timestamp]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !cleanHandle.isEmpty, !snippet.isEmpty else { return nil }

        let query = "\(cleanHandle) \(snippet) site:\(platform.searchDomain)"
        guard let results = await search(query: query) else { return nil }
        return results.first { url in
            guard let host = url.host?.lowercased() else { return false }
            let onPlatform = platform.hosts.contains { host == $0 || host.hasSuffix(".\($0)") }
            let isPost = platform.postMarkers.contains { url.path.lowercased().contains($0) }
            return onPlatform && isPost
        }
    }

    /// Runs a DuckDuckGo HTML search and returns the result URLs in order.
    private static func search(query: String) async -> [URL]? {
        guard var components = URLComponents(string: "https://html.duckduckgo.com/html/") else { return nil }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8)
        else { return nil }
        return resultURLs(inHTML: html)
    }

    /// Extracts the real result URLs from DuckDuckGo HTML, which wraps them as
    /// `…/l/?uddg=<percent-encoded-url>`. Pure, so it's testable.
    static func resultURLs(inHTML html: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: "uddg=([^&\"']+)") else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match -> URL? in
            guard match.numberOfRanges > 1, let r = Range(match.range(at: 1), in: html) else { return nil }
            let encoded = String(html[r])
            guard let decoded = encoded.removingPercentEncoding else { return nil }
            return URL(string: decoded)
        }
    }
}
