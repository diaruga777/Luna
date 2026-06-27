//
//  LeadImageExtractor.swift
//  Clip
//

import Foundation

/// Pulls a representative cover/banner image URL out of an article's HTML —
/// `og:image`, then `twitter:image`, then a `<link rel="image_src">`. Best-effort
/// and pure; the reading-list row falls back to no thumbnail when nothing matches.
public enum LeadImageExtractor {
    public static func imageURL(in html: String, baseURL: URL) -> URL? {
        let patterns = [
            "<meta[^>]+property=[\"']og:image(?::url)?[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+property=[\"']og:image(?::url)?[\"']",
            "<meta[^>]+name=[\"']twitter:image(?::src)?[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "<link[^>]+rel=[\"']image_src[\"'][^>]+href=[\"']([^\"']+)[\"']",
        ]
        for pattern in patterns {
            guard let raw = firstCapture(pattern, in: html) else { continue }
            let cleaned = raw.replacingOccurrences(of: "&amp;", with: "&")
            if let url = URL(string: cleaned, relativeTo: baseURL)?.absoluteURL,
               url.scheme?.hasPrefix("http") == true {
                return url
            }
        }
        return nil
    }

    /// The `content` of a `<meta>` tag for an `og:`/`twitter:` style property or
    /// name (attribute order-independent), with common HTML entities decoded.
    public static func metaContent(property: String, in html: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: property)
        let patterns = [
            "<meta[^>]+property=[\"']\(escaped)[\"'][^>]+content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]+property=[\"']\(escaped)[\"']",
            "<meta[^>]+name=[\"']\(escaped)[\"'][^>]+content=[\"']([^\"']+)[\"']",
        ]
        for pattern in patterns {
            guard let raw = firstCapture(pattern, in: html) else { continue }
            return raw
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "&#39;", with: "'")
                .replacingOccurrences(of: "&quot;", with: "\"")
        }
        return nil
    }

    private static func firstCapture(_ pattern: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range), match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: html)
        else { return nil }
        return String(html[captured])
    }
}
