//
//  DuckDuckGoSearch.swift
//  LunaFetch
//

import Foundation
import LunaModels

/// Shared keyless DuckDuckGo HTML search primitive: builds the request, unwraps
/// DuckDuckGo's redirect-wrapped result URLs, and returns them in order. Used by
/// `SocialPostFinder` (X/TikTok/Instagram/Facebook post lookup), by
/// `SafariPageSave` (Safari webpage title → article lookup), and as the Layer-2
/// leg of the alternative-seller fan-out (`claudedocs/price-comparison.md`).
///
/// It lives in LunaFetch rather than LunaIntents because only the four APPS link
/// LunaIntents: the share and action extensions run the same fan-out at save
/// time, and a search primitive they cannot reach is a search primitive that
/// silently does nothing there. LunaFetch is the lowest tier that already owns
/// the User-Agent this sends.
public enum DuckDuckGoSearch {

    /// Runs a DuckDuckGo HTML search and returns the result URLs in order, or nil
    /// on any network/parsing failure OR on the anomaly/challenge page DuckDuckGo
    /// intermittently serves (a 202, or the same challenge markup under a 200) —
    /// which otherwise passes the 2xx guard and parses to an empty, silently
    /// "successful" result.
    public static func results(forQuery query: String) async -> [URL]? {
        guard var components = URLComponents(string: "https://html.duckduckgo.com/html/") else { return nil }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url,
              LiveNetworkPolicy.allows(url, context: "DuckDuckGoSearch.results")
        else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              let html = String(data: data, encoding: .utf8)
        else { return nil }
        guard http.statusCode != anomalyStatusCode, !isAnomalyPage(html) else { return nil }
        guard (200..<300).contains(http.statusCode) else { return nil }
        return resultURLs(inHTML: html)
    }

    /// The status DuckDuckGo's bot-detection anomaly page is sometimes served
    /// with — distinct from an ordinary 2xx, so it must be checked before the
    /// range guard rather than folded into "not 2xx" (a real 2xx result page
    /// still needs `isAnomalyPage` for the cases where the SAME challenge is
    /// served as an ordinary 200).
    static let anomalyStatusCode = 202

    /// Whether `html` is DuckDuckGo's "unusual traffic" challenge rather than a
    /// results page — measured by its `anomaly-modal` challenge markup, which a
    /// real results page never contains.
    public static func isAnomalyPage(_ html: String) -> Bool {
        html.contains("anomaly-modal") || html.contains("anomaly-modal__check")
    }

    /// Extracts the real result URLs from DuckDuckGo HTML, in document order.
    ///
    /// Two shapes, because the site serves both depending on the request: the
    /// legacy redirect wrapper (`…/l/?uddg=<percent-encoded-url>`) and — what
    /// `html.duckduckgo.com` now actually serves — a DIRECT href on the
    /// `result__a` anchor (`class="result__a" href="https://…"`). The old
    /// parser only understood the first shape, so a 200 page full of real
    /// results parsed to zero links and Layer 2 was silently dead.
    public static func resultURLs(inHTML html: String) -> [URL] {
        var seen: Set<String> = []
        return resultAnchorHrefs(in: html).compactMap { href -> URL? in
            guard let resolved = resolvedResultURLString(fromHref: href),
                  seen.insert(resolved).inserted
            else { return nil }
            return URL(string: resolved)
        }
    }

    /// Every `href` on an anchor carrying DuckDuckGo's `result__a` class, in
    /// document order. `class` and `href` can appear in either order in the
    /// tag, so both are matched.
    static func resultAnchorHrefs(in html: String) -> [String] {
        let pattern = #"<a\b[^>]*(?:class="result__a"[^>]*href="([^"]+)"|href="([^"]+)"[^>]*class="result__a")[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            for group in 1...2 where match.range(at: group).location != NSNotFound {
                guard let r = Range(match.range(at: group), in: html) else { continue }
                return String(html[r]).replacingOccurrences(of: "&amp;", with: "&")
            }
            return nil
        }
    }

    /// A `result__a` href is either a DIRECT absolute URL (what
    /// `html.duckduckgo.com` now actually serves) or the legacy redirect
    /// wrapper (`…/l/?uddg=<percent-encoded-url>`) — either can carry a paid
    /// result (`…/y.js?ad_domain=…`), which is not an organic result.
    static func resolvedResultURLString(fromHref href: String) -> String? {
        guard !href.contains("y.js") else { return nil }
        if let uddgRange = href.range(of: "uddg=") {
            let rest = href[uddgRange.upperBound...]
            let encoded = rest.prefix { $0 != "&" && $0 != "\"" }
            return String(encoded).removingPercentEncoding
        }
        if href.hasPrefix("//") { return "https:" + href }
        guard href.lowercased().hasPrefix("http") else { return nil }
        return href
    }
}
