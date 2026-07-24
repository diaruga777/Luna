//
//  DuckDuckGoSearch.swift
//  LunaPlatforms
//

import LunaFetch
import Foundation

/// Shared keyless DuckDuckGo HTML search primitive: builds the request, unwraps
/// DuckDuckGo's redirect-wrapped result URLs, and returns them in order. Used by
/// `SocialPostFinder` (X/TikTok/Instagram/Facebook post lookup) and by
/// `SafariPageSave` (Safari webpage title → article lookup).
public enum DuckDuckGoSearch {

    /// Runs a DuckDuckGo HTML search and returns the result URLs in order, or nil
    /// on any network/parsing failure.
    public static func results(forQuery query: String) async -> [URL]? {
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
    public static func resultURLs(inHTML html: String) -> [URL] {
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
