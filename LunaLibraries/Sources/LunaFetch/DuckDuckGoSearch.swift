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

    /// One organic result with its link TEXT — what DuckDuckGo prints as the
    /// result headline. `results(forQuery:)` throws the text away because its
    /// callers only ever navigate; the URL-rescue search leg needs it, because a
    /// cross-domain reroute is only allowed when the result is recognizably the
    /// same article (`RescueSearchCandidates.titlesMatch`).
    public struct Entry: Equatable, Sendable {
        public let url: URL
        public let title: String?
        public init(url: URL, title: String?) {
            self.url = url
            self.title = title
        }
    }

    /// The same search as `results(forQuery:)`, keeping each result's headline.
    /// Returns an empty array (not nil) on any failure — the one caller treats
    /// "no candidates" and "search unavailable" identically.
    public static func entries(forQuery query: String) async -> [Entry] {
        guard var components = URLComponents(string: "https://html.duckduckgo.com/html/") else { return [] }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url,
              LiveNetworkPolicy.allows(url, context: "DuckDuckGoSearch.entries")
        else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              let html = String(data: data, encoding: .utf8)
        else { return [] }
        guard http.statusCode != anomalyStatusCode, !isAnomalyPage(html),
              (200..<300).contains(http.statusCode) else { return [] }
        return resultEntries(inHTML: html)
    }

    /// Result URL + link text, in document order, deduplicated by URL. Built
    /// from the same `result__a` anchors `resultURLs(inHTML:)` reads, so the two
    /// stay in step on shape changes.
    public static func resultEntries(inHTML html: String) -> [Entry] {
        var seen: Set<String> = []
        return resultAnchors(in: html).compactMap { anchor -> Entry? in
            guard let resolved = resolvedResultURLString(fromHref: anchor.href),
                  seen.insert(resolved).inserted,
                  let url = URL(string: resolved) else { return nil }
            let title = plainText(anchor.text)
            return Entry(url: url, title: title.isEmpty ? nil : title)
        }
    }

    /// Every `result__a` anchor's href AND inner markup, in document order.
    static func resultAnchors(in html: String) -> [(href: String, text: String)] {
        let pattern = #"<a\b[^>]*(?:class="result__a"[^>]*href="([^"]+)"|href="([^"]+)"[^>]*class="result__a")[^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            var href: String?
            for group in 1...2 where match.range(at: group).location != NSNotFound {
                guard let r = Range(match.range(at: group), in: html) else { continue }
                href = String(html[r]).replacingOccurrences(of: "&amp;", with: "&")
                break
            }
            guard let href else { return nil }
            let text = Range(match.range(at: 3), in: html).map { String(html[$0]) } ?? ""
            return (href, text)
        }
    }

    /// Strips the `<b>` highlighting DuckDuckGo wraps query terms in and decodes
    /// the handful of entities a headline actually carries.
    static func plainText(_ markup: String) -> String {
        var text = markup.replacingOccurrences(
            of: "<[^>]+>", with: "", options: [.regularExpression])
        for (entity, character) in [
            ("&amp;", "&"), ("&quot;", "\""), ("&#x27;", "'"), ("&#39;", "'"),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "),
        ] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
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
