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
        } catch FetchError.tooLarge {
            throw FetchError.tooLarge   // deterministic — a second UA re-downloads the same oversized page
        } catch FetchError.notHTML {
            throw FetchError.notHTML
        } catch {
            // Bot-blocked or transient: many soft paywalls only serve full content
            // to a crawler UA, so retry once as Safari.
            return try await fetch(url: url, userAgent: Self.safariUserAgent)
        }
    }

    /// Common tracking query params stripped before an archive lookup so the
    /// snapshot matches the canonical URL (and a stray fragment can't alter the
    /// archive path).
    private static let trackingParams: Set<String> = [
        "mod", "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "fbclid", "gclid", "igshid", "ref", "cmpid", "ocid", "spm", "smid",
    ]

    /// Canonical form for archive lookups: drops the fragment and known tracking
    /// params. Keeps real query params so distinct articles still resolve. An
    /// already-archived URL is first unwrapped to the original article, so we
    /// archive the real page rather than double-wrapping an archive snapshot.
    static func canonicalForArchiving(_ url: URL) -> URL {
        let article = originalURL(fromArchiveURL: url) ?? url
        guard var comps = URLComponents(url: article, resolvingAgainstBaseURL: false) else { return article }
        comps.fragment = nil
        if let queryItems = comps.queryItems {
            let kept = queryItems.filter { !trackingParams.contains($0.name.lowercased()) }
            comps.queryItems = kept.isEmpty ? nil : kept
        }
        return comps.url ?? article
    }

    /// archive.today's family of interchangeable domains (DNS round-robin; the same
    /// service). A URL on any of these is already an archive snapshot.
    private static let archiveTodayHosts: Set<String> = [
        "archive.today", "archive.is", "archive.ph", "archive.md",
        "archive.li", "archive.vn", "archive.fo",
    ]

    /// Whether `url` is an archive.today snapshot (any of its rotating domains).
    static func isArchiveTodayURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return archiveTodayHosts.contains(host)
    }

    /// The original article URL embedded in an archive.today snapshot URL
    /// (`archive.is/<id|timestamp|newest>/<original>`), or nil when the snapshot
    /// carries no embedded URL (e.g. a bare `archive.is/<id>`).
    static func originalURL(fromArchiveURL url: URL) -> URL? {
        guard isArchiveTodayURL(url) else { return nil }
        let full = url.absoluteString
        // The embedded original begins at the inner http(s):// after the host/path.
        guard let slashScheme = full.range(of: "/https://") ?? full.range(of: "/http://")
        else { return nil }
        let inner = String(full[full.index(after: slashScheme.lowerBound)...])
        return URL(string: inner)
    }

    /// Resolves the URL of the NEWEST archive.today snapshot via the Memento
    /// TimeMap (`/timemap/<url>`) — a plain link-format text endpoint that lives on
    /// archive.today's READ path, so it's far less likely to be CAPTCHA-gated than
    /// the `/newest/<url>` redirect (which triggers archive.today's self-reloading
    /// challenge). Loading the resolved *specific* snapshot is the reliable way in;
    /// returns nil when the TimeMap is unreachable/gated/empty (caller falls back).
    func resolveNewestArchiveSnapshot(for url: URL) async -> URL? {
        let target = Self.canonicalForArchiving(url).absoluteString
        guard let timeMapURL = URL(string: "https://archive.today/timemap/\(target)") else { return nil }
        var request = URLRequest(url: timeMapURL, timeoutInterval: 10)
        request.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= Self.maxBytes,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return Self.newestMemento(fromTimeMap: text)
    }

    /// Parses an RFC 7089 Memento TimeMap (link-format) and returns the newest
    /// snapshot — the `rel="last memento"` entry, else the last memento listed.
    /// Pure (no I/O) so the parsing is unit-testable. Handles the commas inside
    /// `datetime="…, …"` by capturing each `<url>` and the params up to the next `<`.
    static func newestMemento(fromTimeMap text: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: "<([^>]+)>([^<]*)") else { return nil }
        let ns = text as NSString
        var lastMemento: URL?
        var explicitLast: URL?
        regex.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match, match.numberOfRanges >= 3 else { return }
            let urlString = ns.substring(with: match.range(at: 1))
            let params = ns.substring(with: match.range(at: 2)).lowercased()
            guard params.contains("rel="), params.contains("memento"),
                  let memento = URL(string: urlString), isArchiveTodayURL(memento) else { return }
            lastMemento = memento
            if params.contains("last memento") { explicitLast = memento }
        }
        return explicitLast ?? lastMemento
    }

    /// Hosts that hard-paywall or aggressively bot-block, so a direct/background
    /// fetch yields no readable body. For these an unreadable result is parked for a
    /// user-solved archive CAPTCHA (`.needsCaptcha`) rather than failed outright —
    /// the archive snapshot is the only way in, and only an interactive web view
    /// can clear archive.today's Cloudflare gate.
    private static let hardPaywallHosts: Set<String> = [
        "wsj.com", "ft.com", "nytimes.com", "economist.com", "bloomberg.com",
        "washingtonpost.com", "newyorker.com", "theatlantic.com", "wired.com",
        "barrons.com", "businessinsider.com", "theinformation.com", "hbr.org",
        "foreignpolicy.com", "foreignaffairs.com", "thetimes.co.uk", "telegraph.co.uk",
        "nikkei.com", "seekingalpha.com", "latimes.com", "bostonglobe.com",
    ]

    /// Whether `url`'s host (or a subdomain of it) is a known hard-paywall site.
    static func isHardPaywallHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return hardPaywallHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// A human-readable placeholder title for an article we couldn't read yet
    /// (parked for a CAPTCHA), so the list row isn't a bare URL. Derived from the
    /// article slug (the archive URL is unwrapped to the original first); falls back
    /// to the publication/host name. Replaced by the real title once extracted.
    static func articleTitleGuess(from url: URL) -> String {
        let article = originalURL(fromArchiveURL: url) ?? url
        let slug = article.pathComponents.last { !$0.isEmpty && $0 != "/" } ?? ""
        let words = slug
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-").map(String.init)
            // Drop id-ish tokens — all hex/digits (e.g. WSJ's "199845b1", an FT
            // UUID's "c213"); real words contain a non-hex letter (g–z).
            .filter { token in !token.allSatisfy(\.isHexDigit) }
        if words.count >= 2 {
            return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        return (article.host ?? "Article").replacingOccurrences(of: "www.", with: "")
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
        components?.queryItems = [
            URLQueryItem(name: "url", value: Self.canonicalForArchiving(url).absoluteString),
        ]
        guard let apiURL = components?.url else { throw FetchError.badResponse }
        let (data, _) = try await URLSession.shared.data(for: URLRequest(url: apiURL, timeoutInterval: 15))
        guard data.count <= Self.maxBytes,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
        let target = Self.canonicalForArchiving(url).absoluteString
        guard let archiveURL = URL(string: "https://archive.ph/newest/\(target)"),
              archiveURL.host == "archive.ph"   // reject if the article URL smuggled a different host
        else { throw FetchError.badResponse }
        return try await fetch(url: archiveURL, userAgent: Self.safariUserAgent, timeout: 12)
    }

    private func fetch(url: URL, userAgent: String, timeout: TimeInterval = 20) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        // Some sites still serve fuller content to visitors arriving from Google.
        request.setValue("https://www.google.com/", forHTTPHeaderField: "Referer")
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
        let bounded = Self.boundedUTF8(data)
        guard let html = String(data: bounded, encoding: .utf8)
            ?? String(data: bounded, encoding: .isoLatin1)
        else { throw FetchError.notHTML }
        return html
    }

    /// Caps `data` at `maxBytes`, backing up off any partial trailing UTF-8
    /// sequence so a multi-byte character isn't sliced mid-way (which would fail
    /// UTF-8 decoding and silently fall back to garbled ISO-Latin-1).
    private static func boundedUTF8(_ data: Data) -> Data {
        guard data.count > maxBytes else { return data }
        var end = maxBytes
        // 0b10xxxxxx is a UTF-8 continuation byte; the cut point must not land on one.
        while end > 0, data[data.startIndex + end] & 0b1100_0000 == 0b1000_0000 { end -= 1 }
        return data.prefix(end)
    }
}
