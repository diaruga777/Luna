//
//  SafariPageSave.swift
//  LunaIntents
//

import LunaPlatforms
import Foundation

/// Safari has no post-search API to fall back on the way X/TikTok/Reddit do — when
/// the tracked page URL is stale (or never captured) and a screenshot had to be
/// taken instead, the only signal is the model's read of the page's title and
/// site/publication name. This does a best-effort keyless DuckDuckGo search for an
/// article matching that title, filters out obviously-non-article hosts (the
/// search engine itself, redirectors, video platforms), and saves the first
/// surviving result. Known-fuzzy — flagged for on-device QA across a range of
/// sites.
public enum SafariPageSave {

    public enum SaveError: Error {
        case notFound
    }

    /// Hosts that are never the article itself — the search engine, generic
    /// redirectors, and video platforms that wouldn't match a "title ; site"
    /// screen read anyway. `google.*` is matched by prefix to catch every
    /// country TLD (google.co.uk, google.de, …).
    static let nonArticleHosts: [String] = [
        "duckduckgo.com", "bing.com", "youtube.com", "youtu.be",
    ]

    /// Builds the DuckDuckGo query: the title quoted for an exact-phrase match,
    /// plus the site as a plain (unquoted) keyword when present.
    static func searchQuery(title: String, site: String?) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return "" }
        var parts = ["\"\(trimmedTitle)\""]
        if let site = site?.trimmingCharacters(in: .whitespacesAndNewlines), !site.isEmpty {
            parts.append(site)
        }
        return parts.joined(separator: " ")
    }

    /// Drops search-result URLs that can't be the article itself.
    static func filterArticleCandidates(_ urls: [URL]) -> [URL] {
        urls.filter { url in
            guard let host = url.host?.lowercased() else { return false }
            return !isNonArticleHost(host)
        }
    }

    private static func isNonArticleHost(_ host: String) -> Bool {
        if host.contains("google.") { return true }
        return nonArticleHosts.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// Searches for and saves the article matching `title`/`site`, throwing
    /// `.notFound` when nothing survives the host filter.
    public static func save(
        title: String, site: String?, doubleSaveActionSurface: String?,
        saveTimeout: TimeInterval = IntentSaveTimeout.standard
    ) async throws -> IntentIngestHelper.ActionButtonSaveOutcome {
        let query = searchQuery(title: title, site: site)
        guard !query.isEmpty, let results = await DuckDuckGoSearch.results(forQuery: query)
        else { throw SaveError.notFound }
        guard let match = filterArticleCandidates(results).first else { throw SaveError.notFound }
        return await IntentIngestHelper.handleSavePress(
            urlString: match.absoluteString, doubleSaveActionSurface: doubleSaveActionSurface,
            timeout: saveTimeout)
    }
}
