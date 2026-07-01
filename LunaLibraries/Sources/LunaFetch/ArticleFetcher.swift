//
//  ArticleFetcher.swift
//  Luna
//

import LunaFetch
import LunaHTMLClassification
import LunaURLClassification
import Foundation

/// The HTML-fetching surface the resolver and `BypassRunner` depend on, so both are
/// unit-testable against a mock without touching the network. `ArticleFetcher` is the
/// live implementation; `MockArticleFetcher` (tests) records calls and returns canned
/// HTML.
public protocol HTMLFetching {
    /// Fetches HTML for `url` with a single, deterministic Safari UA — the bytes a
    /// normal reader sees, so the paywall judgment is computed over reader-served HTML
    /// and re-runs are reproducible. The Googlebot crawler trick is NOT the default; it
    /// is an explicit `.userAgent(.googlebotDesktop)` bypass strategy.
    func fetchHTML(from url: URL) async throws -> String
    /// Fetches `url` with an explicit crawler User-Agent and optional
    /// `X-Forwarded-For` (for crawler-whitelist paywalls).
    func fetchHTML(from url: URL, userAgent: String, xForwardedFor: String?) async throws -> String
    /// Fetches `url` sending a spoofed `Referer` (e.g. arriving "from Google").
    func fetchHTML(from url: URL, referer: String) async throws -> String
    /// Fetches `url` through an ephemeral session that sends no stored cookies (a
    /// fresh-session / "incognito" fetch that resets a client-side meter).
    func fetchHTMLWithoutCookies(from url: URL) async throws -> String
    /// Resolves the newest Wayback 200 snapshot (CDX, then Availability) and fetches
    /// its raw `id_` replay — un-mangled source HTML the extractor likes.
    func fetchWaybackRawHTML(for url: URL) async throws -> String
    /// Fetches the r.jina.ai reader rendering of `url` (`https://r.jina.ai/<url>`).
    func fetchJinaReader(for url: URL) async throws -> String
}

/// Downloads raw HTML for a weblink with a single, deterministic Safari user agent
/// (the bytes a normal reader sees). The Googlebot crawler trick — which many soft
/// paywalls serve full content to — is no longer the default read; it is an explicit
/// `.userAgent(.googlebotDesktop)` bypass strategy (`CrawlerAgent.googlebotDesktop`),
/// so the direct read is reproducible and the paywall judgment isn't computed over
/// crawler-served HTML.
public struct ArticleFetcher: HTMLFetching {
    public init() {}

    public static let safariUserAgent = WebFetchConstants.safariUserAgent
    /// Cap on the HTML we hold in memory. Real article pages are far smaller;
    /// this keeps a mis-served large file or huge page from pushing the
    /// memory-limited share/action extension into jetsam.
    public static let maxBytes = WebFetchConstants.maxBytes

    public enum FetchError: Error {
        case badResponse
        case notHTML
        case tooLarge
    }

    public func fetchHTML(from url: URL) async throws -> String {
        // ONE UA, no fallback chain: deterministic + reproducible. A bot-blocked soft
        // paywall is recovered by the explicit `.userAgent(.googlebotDesktop)` bypass
        // strategy, not by silently swapping the UA on the direct read.
        try await fetch(url: url, userAgent: Self.safariUserAgent)
    }

    /// Canonical form for archive lookups: an already-archived URL is first
    /// unwrapped to the original article (so we archive the real page rather than
    /// double-wrapping a snapshot), then tracking-stripped via the single
    /// `URLCanonicalizer.strip` shared with the unwrap path.
    public static func canonicalForArchiving(_ url: URL) -> URL {
        URLCanonicalizer.strip(originalURL(fromArchiveURL: url) ?? url)
    }

    /// archive.today's family of interchangeable domains (DNS round-robin; the same
    /// service). A URL on any of these is already an archive snapshot.
    private static let archiveTodayHosts: Set<String> = [
        "archive.today", "archive.is", "archive.ph", "archive.md",
        "archive.li", "archive.vn", "archive.fo",
    ]

    /// Whether `url` is an archive.today snapshot (any of its rotating domains).
    public static func isArchiveTodayURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return archiveTodayHosts.contains(host)
    }

    /// The original article URL embedded in an archive.today snapshot URL
    /// (`archive.is/<id|timestamp|newest>/<original>`), or nil when the snapshot
    /// carries no embedded URL (e.g. a bare `archive.is/<id>`).
    public static func originalURL(fromArchiveURL url: URL) -> URL? {
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
    public func resolveNewestArchiveSnapshot(for url: URL) async -> URL? {
        let target = Self.canonicalForArchiving(url).absoluteString
        guard let timeMapURL = URL(string: "https://archive.is/timemap/\(target)") else { return nil }
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
    public static func newestMemento(fromTimeMap text: String) -> URL? {
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

    /// Whether `url`'s host (or a subdomain of it) is a known hard-paywall /
    /// aggressively bot-blocking site, for which a direct/background fetch yields no
    /// readable body — so an unreadable result is parked for a user-solved archive
    /// CAPTCHA (`.needsCaptcha`) rather than failed outright (the archive snapshot is
    /// the only way in, and only an interactive web view can clear archive.today's
    /// Cloudflare gate).
    ///
    /// SINGLE SOURCE: a host is hard-paywall iff the classifier's
    /// `hardPaywallNewsSites` table names it — the SAME list the classifier uses to
    /// return `.paywalledArticle(hardHost: true)`, so determination and the
    /// "unreadable → park for archive" routing can never drift. (`BypassRuleTable`
    /// only refines the per-host bypass STRATEGY ordering; a hard-paywall host with no
    /// bespoke rule still routes to the archive reader via the generic plan.)
    public static func isHardPaywallHost(_ url: URL) -> Bool {
        Classifier.isHardPaywallHost(url)
    }

    /// A human-readable placeholder title for an article we couldn't read yet
    /// (parked for a CAPTCHA), so the list row isn't a bare URL. Derived from the
    /// article slug (the archive URL is unwrapped to the original first); falls back
    /// to the publication/host name. Replaced by the real title once extracted.
    public static func articleTitleGuess(from url: URL) -> String {
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

    // MARK: - Bypass-strategy fetches (HTMLFetching)

    public func fetchHTML(from url: URL, userAgent: String, xForwardedFor: String?) async throws -> String {
        // Crawler reads go over a cookieless (ephemeral) session: a real Googlebot
        // presents no cookies, and clearing them means a stale "non-subscriber"
        // cookie can't tag us as gated — exactly what browser paywall extensions do
        // for WSJ (googlebot UA + cleared cookies).
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await fetch(url: url, userAgent: userAgent, xForwardedFor: xForwardedFor,
                               timeout: 12, session: session)
    }

    public func fetchHTML(from url: URL, referer: String) async throws -> String {
        try await fetch(url: url, userAgent: Self.safariUserAgent, referer: referer, timeout: 12)
    }

    public func fetchHTMLWithoutCookies(from url: URL) async throws -> String {
        // An ephemeral session has no cookie store, so a client-side cookie meter sees
        // a brand-new visitor. The session is local to this call and discarded after.
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        return try await fetch(url: url, userAgent: Self.safariUserAgent, timeout: 12, session: session)
    }

    public func fetchJinaReader(for url: URL) async throws -> String {
        let target = Self.canonicalForArchiving(url).absoluteString
        guard let jinaURL = URL(string: "https://r.jina.ai/" + target) else { throw FetchError.badResponse }
        return try await fetch(url: jinaURL, userAgent: Self.safariUserAgent, timeout: 20)
    }

    /// Resolves the newest Wayback 200 snapshot via the CDX API (newest rows, drop
    /// tiny/non-200), then fetches the raw `…/web/<ts>id_/<url>` replay (the `id_`
    /// suffix strips IA's banner/asset rewriting). Falls back to the rewritten
    /// Availability-API replay when CDX returns nothing.
    public func fetchWaybackRawHTML(for url: URL) async throws -> String {
        let canonical = Self.canonicalForArchiving(url).absoluteString
        if let timestamp = try? await waybackNewestTimestamp(forCanonical: canonical),
           let rawURL = URL(string: "https://web.archive.org/web/\(timestamp)id_/\(canonical)") {
            return try await fetch(url: rawURL, userAgent: Self.safariUserAgent, timeout: 30)
        }
        return try await fetchWaybackHTML(for: url)
    }

    /// CDX newest-200 lookup → the snapshot timestamp, or nil when none is available.
    private func waybackNewestTimestamp(forCanonical canonical: String) async throws -> String? {
        var components = URLComponents(string: "https://web.archive.org/cdx/search/cdx")
        components?.queryItems = [
            URLQueryItem(name: "url", value: canonical),
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "filter", value: "statuscode:200"),
            URLQueryItem(name: "collapse", value: "digest"),
            URLQueryItem(name: "limit", value: "-5"),
            URLQueryItem(name: "fastLatest", value: "true"),
        ]
        guard let cdxURL = components?.url else { return nil }
        var request = URLRequest(url: cdxURL, timeoutInterval: 15)
        request.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= Self.maxBytes
        else { return nil }
        return Self.newestSnapshotTimestamp(fromCDXJSON: data)
    }

    /// Parses a Wayback CDX JSON response (an array of rows, the first being the
    /// header `[urlkey,timestamp,original,mimetype,statuscode,digest,length]`) and
    /// returns the newest non-trivial snapshot's 14-digit timestamp. Pure (no I/O) so
    /// the parsing is unit-testable. Rows are returned oldest→newest; with
    /// `filter=statuscode:200` they're all 200s, so we take the last row whose body
    /// `length` isn't trivially small (a tiny capture is a stub, not the article).
    public static func newestSnapshotTimestamp(fromCDXJSON data: Data) -> String? {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]],
              rows.count > 1 else { return nil }

        func stringValue(_ value: Any?) -> String? {
            if let string = value as? String { return string }
            if let number = value as? NSNumber { return number.stringValue }
            return nil
        }
        // Locate the columns from the header so we don't hardcode indices.
        let header = rows[0].compactMap { stringValue($0) }
        let timestampIndex = header.firstIndex(of: "timestamp") ?? 1
        let statusIndex = header.firstIndex(of: "statuscode") ?? 4
        let lengthIndex = header.firstIndex(of: "length") ?? 6
        let minLength = 1024   // a 200 capture this small is a stub/redirect shell

        var newest: String?
        for row in rows.dropFirst() {
            guard row.count > timestampIndex,
                  let timestamp = stringValue(row[timestampIndex]),
                  timestamp.count == 14, timestamp.allSatisfy(\.isNumber)
            else { continue }
            if row.count > statusIndex, let status = stringValue(row[statusIndex]), status != "200" { continue }
            if row.count > lengthIndex, let length = stringValue(row[lengthIndex]),
               let bytes = Int(length), bytes < minLength { continue }
            newest = timestamp   // rows are oldest→newest, so the last qualifying wins
        }
        return newest
    }

    private func fetch(
        url: URL, userAgent: String, referer: String = "https://www.google.com/",
        xForwardedFor: String? = nil, timeout: TimeInterval = 20, session: URLSession = .shared
    ) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        // Some sites still serve fuller content to visitors arriving from Google.
        request.setValue(referer, forHTTPHeaderField: "Referer")
        if let xForwardedFor {
            request.setValue(xForwardedFor, forHTTPHeaderField: "X-Forwarded-For")
        }
        let (data, response) = try await session.data(for: request)
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
