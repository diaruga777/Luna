//
//  SocialPostFinder.swift
//  Luna
//

import LunaFetch
import LunaModels
import LunaURLClassification
import Foundation

/// Finds a specific social post's URL for platforms with no public search API
/// (X, TikTok, Instagram, Facebook), from the author handle plus a content
/// snippet and/or timestamp, via a keyless DuckDuckGo HTML search. Best-effort:
/// returns nil when nothing convincingly matches.
public enum SocialPostFinder {

    public enum Platform {
        case x, tiktok, instagram, facebook

        /// The `PlatformRecognizer` platform this case corresponds to.
        private var recognized: ContentPlatform {
            switch self {
            case .x: return .x
            case .tiktok: return .tiktok
            case .instagram: return .instagram
            case .facebook: return .facebook
            }
        }

        /// Hosts that count as this platform, looked up from `PlatformRecognizer`'s
        /// canonical table rather than a hand-maintained copy.
        var hosts: [String] {
            PlatformRecognizer.rules.first { $0.platform == recognized }?.hosts ?? []
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
    public static func findPostURL(
        platform: Platform, handle: String, content: String?, timestamp: String?
    ) async -> URL? {
        let cleanHandle = handle.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "", options: [.anchored])
        let phrase = sanitizedPhrase(content)
        let time = timestamp?.trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty
        guard !cleanHandle.isEmpty, phrase != nil || time != nil else { return nil }

        // Try progressively looser queries, returning the first convincing match.
        // The phrase is quoted first for an exact match, then unquoted; the final
        // attempt drops the `site:` filter and relies on the result host filter
        // (catches x.com posts that the engine indexed under twitter.com, etc.).
        let quoted = phrase.map { "\"\($0)\"" }
        let queries: [String] = [
            query(handle: cleanHandle, phrase: quoted, time: time, scoped: platform),
            query(handle: cleanHandle, phrase: phrase, time: time, scoped: platform),
            query(handle: cleanHandle, phrase: quoted, time: time, scoped: nil),
        ].removingDuplicatesAndEmpties()

        for query in queries {
            guard let results = await search(query: query) else { continue }
            if let match = bestMatch(in: results, platform: platform, handle: cleanHandle) {
                return match
            }
        }
        return nil
    }

    /// Builds a search query string. With `scoped` set, restricts to that platform's
    /// search domain; otherwise leaves the result host filter to do the narrowing.
    private static func query(
        handle: String, phrase: String?, time: String?, scoped: Platform?
    ) -> String {
        var parts = ["\(handle)"]
        if let phrase { parts.append(phrase) }
        if let time { parts.append(time) }
        if let scoped { parts.append("site:\(scoped.searchDomain)") }
        return parts.joined(separator: " ")
    }

    /// Picks the best post URL from search results: it must be on the platform and
    /// look like a post (not a profile/home). A result whose path contains the
    /// author handle wins over one that merely matches the host + post marker.
    public static func bestMatch(in urls: [URL], platform: Platform, handle: String) -> URL? {
        let needle = handle.lowercased()
        let posts = urls.filter { url in
            guard let host = url.host?.lowercased() else { return false }
            let onPlatform = HostMatching.hostSuffixMatches(host, anyOf: platform.hosts)
            let isPost = platform.postMarkers.contains { url.path.lowercased().contains($0) }
            return onPlatform && isPost
        }
        return posts.first { $0.path.lowercased().contains(needle) } ?? posts.first
    }

    /// Trims a post phrase, strips surrounding quotes, and caps its length so the
    /// query stays focused (very long phrases over-constrain the search).
    private static func sanitizedPhrase(_ content: String?) -> String? {
        guard var phrase = content?.trimmingCharacters(in: .whitespacesAndNewlines), !phrase.isEmpty
        else { return nil }
        phrase = phrase.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’"))
        let words = phrase.split(separator: " ")
        if words.count > 12 { phrase = words.prefix(12).joined(separator: " ") }
        return phrase.nilIfEmpty
    }

    /// Runs a DuckDuckGo HTML search and returns the result URLs in order.
    private static func search(query: String) async -> [URL]? {
        await DuckDuckGoSearch.results(forQuery: query)
    }

    /// Extracts the real result URLs from DuckDuckGo HTML, which wraps them as
    /// `…/l/?uddg=<percent-encoded-url>`. Pure, so it's testable. Forwards to the
    /// shared `DuckDuckGoSearch` implementation.
    public static func resultURLs(inHTML html: String) -> [URL] {
        DuckDuckGoSearch.resultURLs(inHTML: html)
    }
}

private extension String {
    /// nil when the string is empty (after no further trimming).
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension Array where Element == String {
    /// Drops empty strings and later duplicates, preserving order.
    func removingDuplicatesAndEmpties() -> [String] {
        var seen = Set<String>()
        return filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
