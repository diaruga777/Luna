//
//  ArticleFetcher.swift
//  Clip
//

import Foundation

/// Downloads raw HTML for a weblink. Requests with a Googlebot user agent first —
/// many soft paywalls serve full content to crawlers and never trigger without
/// JavaScript — and falls back to a regular Safari user agent.
struct ArticleFetcher {
    static let googlebotUserAgent =
        "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
    static let safariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
    /// Cap on the HTML we hold in memory. Real article pages are far smaller;
    /// this keeps a mis-served large file or huge page from pushing the
    /// memory-limited share/action extension into jetsam.
    static let maxBytes = 8 * 1024 * 1024

    enum FetchError: Error {
        case badResponse
        case notHTML
        case tooLarge
    }

    func fetchHTML(from url: URL) async throws -> String {
        do {
            return try await fetch(url: url, userAgent: Self.googlebotUserAgent)
        } catch {
            return try await fetch(url: url, userAgent: Self.safariUserAgent)
        }
    }

    /// Fetches a public web-archive copy of a URL — a fallback for hard-paywalled /
    /// bot-blocked pages (WSJ, FT, …) the direct fetch can't read (401, or only a
    /// subscription stub). Tries the **Wayback Machine** first (automation-friendly,
    /// no CAPTCHA, often carries the full text), then **archive.today** (user-submitted
    /// snapshots that bypass more paywalls but rate-limit/CAPTCHA aggressively).
    func fetchArchivedHTML(for url: URL) async throws -> String {
        if let wayback = try? await fetchWaybackHTML(for: url) { return wayback }
        return try await fetchArchiveTodayHTML(for: url)
    }

    /// The Wayback Machine's replay snapshot. (NOT the `id_` raw variant — for JS-heavy
    /// sites like WSJ the raw capture is a contentless app shell, whereas the replay
    /// preserves the server-rendered article body the extractor needs.)
    private func fetchWaybackHTML(for url: URL) async throws -> String {
        var components = URLComponents(string: "https://archive.org/wayback/available")
        components?.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        guard let apiURL = components?.url else { throw FetchError.badResponse }
        let (data, _) = try await URLSession.shared.data(from: apiURL)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshots = json["archived_snapshots"] as? [String: Any],
              let closest = snapshots["closest"] as? [String: Any],
              (closest["available"] as? Bool) == true,
              let snapshotString = closest["url"] as? String,
              // The API returns http://; https avoids an ATS upgrade round-trip.
              let snapshotURL = URL(string: snapshotString.replacingOccurrences(
                of: "http://web.archive.org", with: "https://web.archive.org"))
        else { throw FetchError.badResponse }
        return try await fetch(url: snapshotURL, userAgent: Self.safariUserAgent, timeout: 30)
    }

    /// `archive.ph/newest/<url>` 302-redirects to the latest archive.today snapshot,
    /// which URLSession follows. Succeeds only for the minority of IPs archive.today
    /// doesn't challenge; everyone else gets a Cloudflare CAPTCHA (which a `URLSession`
    /// can't solve) and falls through to the interactive `ArchiveWebReaderViewController`.
    /// Short timeout so that common failure doesn't stall the foreground share sheet.
    private func fetchArchiveTodayHTML(for url: URL) async throws -> String {
        guard let archiveURL = URL(string: "https://archive.ph/newest/\(url.absoluteString)") else {
            throw FetchError.badResponse
        }
        return try await fetch(url: archiveURL, userAgent: Self.safariUserAgent, timeout: 12)
    }

    private func fetch(url: URL, userAgent: String, timeout: TimeInterval = 20) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw FetchError.badResponse
        }
        // A server that declares an oversized body (a mis-served large file) is
        // rejected outright. For everything else, bound the page we parse so the
        // memory-limited extension can't be pushed into jetsam by a huge page.
        if http.expectedContentLength > Int64(Self.maxBytes) {
            throw FetchError.tooLarge
        }
        let bounded = data.count > Self.maxBytes ? data.prefix(Self.maxBytes) : data
        guard let html = String(data: bounded, encoding: .utf8)
            ?? String(data: bounded, encoding: .isoLatin1)
        else { throw FetchError.notHTML }
        return html
    }
}
