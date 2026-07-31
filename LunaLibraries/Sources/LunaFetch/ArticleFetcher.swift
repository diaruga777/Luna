//
//  ArticleFetcher.swift
//  Luna
//

import LunaHTMLClassification
import LunaModels
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
    /// Resolves the OLDEST Wayback 200 snapshot and fetches its raw `id_` replay — the
    /// capture that predates a paywall the publisher added after publication.
    func fetchWaybackPrePaywallHTML(for url: URL) async throws -> String
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

    public enum FetchError: Error, Equatable {
        /// A non-2xx answer. The status code is carried so a failed save can say
        /// WHICH refusal it was (403 blocked vs 404 gone vs 429 rate-limited);
        /// nil when the response wasn't even an HTTP response.
        case badResponse(status: Int?)
        case notHTML
        case tooLarge
        /// The request for an ARTICLE was redirected into the publisher's own
        /// subscribe / sign-in / cookie-check interstitial (`landedOn`). A 200 with
        /// a body — but the body is the subscription pitch, not the article, and it
        /// runs long enough and clean enough of gate wording to read as a perfectly
        /// good article to the extractor. So the fetch FAILS here instead: the page
        /// we asked for was never served (News Corp's
        /// `…/subscribe/news/1/?dest=<article>` is the live case).
        case subscribeRedirect(landedOn: URL)
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
        return (article.host ?? L10n.string("Article"))
            .replacingOccurrences(of: "www.", with: "")
    }

    /// The replay URL of the capture CLOSEST to now, from the Availability API. (NOT
    /// the `id_` raw variant — for JS-heavy sites like WSJ the raw capture is a
    /// contentless app shell, whereas the replay preserves the server-rendered article
    /// body the extractor needs.) Nil when nothing is archived / the API didn't answer.
    ///
    /// This asks the SAME question as the CDX `.newest` lookup, but of a different,
    /// much faster service — which is why `fetchWaybackRawHTML` races the two rather
    /// than reaching for this only after CDX has already spent its timeout.
    private func availabilityReplayURL(forCanonical canonical: String) async -> URL? {
        var components = URLComponents(string: "https://archive.org/wayback/available")
        components?.queryItems = [URLQueryItem(name: "url", value: canonical)]
        guard let apiURL = components?.url,
              let (data, _) = try? await URLSession.shared.data(
                for: URLRequest(url: apiURL, timeoutInterval: Self.waybackIndexTimeout)),
              data.count <= Self.maxBytes,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let snapshots = json["archived_snapshots"] as? [String: Any],
              let closest = snapshots["closest"] as? [String: Any],
              (closest["available"] as? Bool) == true,
              let snapshotString = closest["url"] as? String
        else { return nil }
        // The API returns http://; https avoids an ATS upgrade round-trip.
        return URL(string: snapshotString.replacingOccurrences(
            of: "http://web.archive.org", with: "https://web.archive.org"))
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
        guard let jinaURL = URL(string: "https://r.jina.ai/" + target) else { throw FetchError.badResponse(status: nil) }
        return try await fetch(url: jinaURL, userAgent: Self.safariUserAgent, timeout: 20)
    }

    /// Resolves the newest Wayback 200 snapshot and fetches its replay.
    ///
    /// The CDX index is still the PREFERRED resolver — it filters to non-trivial 200
    /// captures and addresses the raw `…/web/<ts>id_/<url>` replay (the `id_` suffix
    /// strips IA's banner/asset rewriting) — but it is no longer the only one on the
    /// clock. CDX either answers in about a second or effectively stops answering:
    /// three consecutive lookups of ONE WSJ article measured 16s (timed out), 1.7s and
    /// 14s, while every Availability call for the same URL answered in ≤0.6s. So both
    /// lookups start TOGETHER and CDX gets only `waybackIndexGrace` more once a usable
    /// Availability snapshot is in hand. That turns the slowest step in a paywalled
    /// save from "up to the full index timeout" into "about as long as the fast
    /// service takes", without giving up the better answer when it arrives in time.
    public func fetchWaybackRawHTML(for url: URL) async throws -> String {
        let canonical = Self.canonicalForArchiving(url).absoluteString
        let indexed = Task { try? await waybackTimestamp(forCanonical: canonical, end: .newest) }
        let available = Task { await availabilityReplayURL(forCanonical: canonical) }
        defer { indexed.cancel(); available.cancel() }

        if let timestamp = await preferredTimestamp(indexed, orFallbackFrom: available) {
            return try await fetchWaybackRaw(timestamp: timestamp, canonical: canonical)
        }
        guard let replayURL = await available.value else { throw FetchError.badResponse(status: nil) }
        return try await fetch(url: replayURL, userAgent: Self.safariUserAgent, timeout: 30)
    }

    /// Resolves the OLDEST Wayback 200 snapshot and fetches its raw `id_` replay — the
    /// capture most likely to PREDATE a wall the publisher added later.
    ///
    /// A paywall is a property of the site at a moment in time, not of the article: The
    /// Paris Review put its interview archive online free and metered it years later, so
    /// every recent capture of a 1969 interview carries the same truncated preview the
    /// live page serves while the 2010–2016 captures hold the whole 50 000-character
    /// piece. Newest-first (`fetchWaybackRawHTML`) is right for an article that was
    /// walled from publication — where the oldest capture is just an older wall — so
    /// the readability gate picks the winner between the two.
    ///
    /// Skips the download when the first capture is too RECENT for that era to exist
    /// (`captureCouldPredateAWall`) — a story archived for the first time last week was
    /// walled the day it was published, so its oldest capture is byte-for-byte the same
    /// wall as its newest.
    ///
    /// Throws rather than falling back to the Availability API: that API only answers
    /// "closest to now", which is exactly the capture the newest-first attempt already
    /// tried.
    public func fetchWaybackPrePaywallHTML(for url: URL) async throws -> String {
        let canonical = Self.canonicalForArchiving(url).absoluteString
        guard let timestamp = try? await waybackTimestamp(
                forCanonical: canonical, end: .oldest,
                timeout: Self.waybackSpeculativeIndexTimeout),
              Self.captureCouldPredateAWall(timestamp)
        else { throw FetchError.badResponse(status: nil) }
        return try await fetchWaybackRaw(timestamp: timestamp, canonical: canonical)
    }

    /// Awaits the CDX timestamp, but abandons it `waybackIndexGrace` after `available`
    /// has produced a usable snapshot — so a stalled index costs a save a couple of
    /// seconds rather than its whole timeout. When the Availability API has nothing to
    /// offer there is no cheaper answer to fall back to, so CDX is waited out in full.
    private func preferredTimestamp(
        _ indexed: Task<String?, Never>, orFallbackFrom available: Task<URL?, Never>
    ) async -> String? {
        enum Leg: Sendable {
            case indexed(String?)
            case graceExpired
        }
        return await withTaskGroup(of: Leg.self) { group in
            group.addTask { .indexed(await indexed.value) }
            group.addTask {
                // No fallback → the index is the only hope; let its own timeout bound it.
                let wait = await available.value == nil
                    ? Self.waybackIndexTimeout
                    : Self.waybackIndexGrace
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                return .graceExpired
            }
            var winner: String?
            if case let .indexed(timestamp) = await group.next() ?? .graceExpired {
                winner = timestamp
            }
            group.cancelAll()
            return winner
        }
    }

    /// The raw `…/web/<ts>id_/<url>` replay for a resolved snapshot (the `id_` suffix
    /// strips IA's banner/asset rewriting).
    private func fetchWaybackRaw(timestamp: String, canonical: String) async throws -> String {
        guard let rawURL = URL(string: "https://web.archive.org/web/\(timestamp)id_/\(canonical)")
        else { throw FetchError.badResponse(status: nil) }
        return try await fetch(url: rawURL, userAgent: Self.safariUserAgent, timeout: 30)
    }

    /// Which end of an article's capture history a Wayback lookup wants.
    private enum SnapshotEnd {
        case newest
        case oldest
    }

    /// How long a Wayback INDEX lookup may take. Deliberately far shorter than a content
    /// fetch (30s): an index lookup is one small JSON row set, and the CDX server either
    /// serves it in about a second or not at all. The old 15s here was the single
    /// slowest step in a hard-paywalled save.
    static let waybackIndexTimeout: TimeInterval = 8

    /// The budget for a SPECULATIVE index lookup — one whose strategy is a long shot
    /// rather than the route the save depends on (`.waybackPrePaywall`). A long shot
    /// earns a long-shot budget: CDX answers a healthy lookup in 1–2s, so this catches
    /// the case where it can pay off and abandons the case where it would only make the
    /// user wait. Without it a stalled index on the speculative leg sets the whole
    /// fanned-out silent tier's wall clock, since failure can't be declared until every
    /// attempt has answered.
    static let waybackSpeculativeIndexTimeout: TimeInterval = 4

    /// How much longer the CDX index gets once the Availability API has already produced
    /// a usable snapshot. CDX stays preferred — it filters out tiny stub captures — but
    /// never at the price of several more seconds of a share sheet's spinner when an
    /// answer is already in hand. Sized off the measured split: a healthy CDX lookup
    /// takes 1.1–1.7s and started ~0.6s before this timer did, so it clears comfortably,
    /// while a sick one (8s+) is abandoned about two seconds in.
    static let waybackIndexGrace: TimeInterval = 1.5

    /// How old a page's FIRST capture must be for a pre-paywall snapshot to plausibly
    /// exist. `.waybackPrePaywall` hunts for the era before a publisher metered
    /// something it had published free — The Paris Review's 1969 interviews, walled
    /// decades later. An article whose earliest capture is days old was walled the day
    /// it was published, so its oldest capture carries the identical wall and replaying
    /// it is a second archive download that provably cannot help. Six months is
    /// deliberately generous: the cost of being wrong is one skipped long-shot, and the
    /// cost of never skipping is that every save of a brand-new hard-paywalled story
    /// pays for the leg.
    public static let prePaywallCaptureMinimumAge: TimeInterval = 180 * 24 * 60 * 60

    /// Whether a capture taken at `timestamp` is old enough to predate a wall the
    /// publisher added after publication. Pure (takes `now`) so the policy is
    /// unit-testable. An unparseable timestamp answers true — the skip is an
    /// optimization and must never suppress a strategy on bad data.
    public static func captureCouldPredateAWall(_ timestamp: String, now: Date = Date()) -> Bool {
        guard let captured = waybackDate(fromTimestamp: timestamp) else { return true }
        return now.timeIntervalSince(captured) >= prePaywallCaptureMinimumAge
    }

    /// Parses a Wayback 14-digit `yyyyMMddHHmmss` UTC timestamp.
    public static func waybackDate(fromTimestamp timestamp: String) -> Date? {
        guard timestamp.count == 14, timestamp.allSatisfy(\.isNumber) else { return nil }
        return waybackTimestampFormatter.date(from: timestamp)
    }

    private static let waybackTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter
    }()

    /// CDX 200-only lookup at one end of the capture history → the snapshot timestamp,
    /// or nil when none is available. A negative `limit` returns the LAST n rows (newest,
    /// with `fastLatest` letting IA answer from the tail of the index); a positive one
    /// returns the first n (oldest).
    private func waybackTimestamp(
        forCanonical canonical: String, end: SnapshotEnd,
        timeout: TimeInterval = ArticleFetcher.waybackIndexTimeout
    ) async throws -> String? {
        var components = URLComponents(string: "https://web.archive.org/cdx/search/cdx")
        var queryItems = [
            URLQueryItem(name: "url", value: canonical),
            URLQueryItem(name: "output", value: "json"),
            URLQueryItem(name: "filter", value: "statuscode:200"),
            URLQueryItem(name: "collapse", value: "digest"),
            URLQueryItem(name: "limit", value: end == .newest ? "-5" : "5"),
        ]
        if end == .newest {
            queryItems.append(URLQueryItem(name: "fastLatest", value: "true"))
        }
        components?.queryItems = queryItems
        guard let cdxURL = components?.url else { return nil }
        var request = URLRequest(url: cdxURL, timeoutInterval: timeout)
        request.setValue(Self.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= Self.maxBytes
        else { return nil }
        switch end {
        case .newest: return Self.newestSnapshotTimestamp(fromCDXJSON: data)
        case .oldest: return Self.oldestSnapshotTimestamp(fromCDXJSON: data)
        }
    }

    /// Parses a Wayback CDX JSON response (an array of rows, the first being the
    /// header `[urlkey,timestamp,original,mimetype,statuscode,digest,length]`) and
    /// returns the newest non-trivial snapshot's 14-digit timestamp. Pure (no I/O) so
    /// the parsing is unit-testable. Rows are returned oldest→newest; with
    /// `filter=statuscode:200` they're all 200s, so we take the last row whose body
    /// `length` isn't trivially small (a tiny capture is a stub, not the article).
    public static func newestSnapshotTimestamp(fromCDXJSON data: Data) -> String? {
        // Rows are oldest→newest, so the LAST qualifying one is the newest.
        qualifyingSnapshotTimestamps(fromCDXJSON: data).last
    }

    /// The OLDEST non-trivial 200 snapshot's 14-digit timestamp in a CDX response — the
    /// capture most likely to predate a later-added paywall (see
    /// `fetchWaybackPrePaywallHTML`). Pure, same parsing as
    /// `newestSnapshotTimestamp(fromCDXJSON:)`, opposite end.
    public static func oldestSnapshotTimestamp(fromCDXJSON data: Data) -> String? {
        qualifyingSnapshotTimestamps(fromCDXJSON: data).first
    }

    /// Every usable snapshot timestamp in a CDX response, in the API's own oldest→newest
    /// row order: 14-digit, status 200, and a body `length` that isn't trivially small (a
    /// tiny capture is a stub/redirect shell, not the article).
    private static func qualifyingSnapshotTimestamps(fromCDXJSON data: Data) -> [String] {
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]],
              rows.count > 1 else { return [] }

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

        var timestamps: [String] = []
        for row in rows.dropFirst() {
            guard row.count > timestampIndex,
                  let timestamp = stringValue(row[timestampIndex]),
                  timestamp.count == 14, timestamp.allSatisfy(\.isNumber)
            else { continue }
            if row.count > statusIndex, let status = stringValue(row[statusIndex]), status != "200" { continue }
            if row.count > lengthIndex, let length = stringValue(row[lengthIndex]),
               let bytes = Int(length), bytes < minLength { continue }
            timestamps.append(timestamp)
        }
        return timestamps
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
            throw FetchError.badResponse(status: (response as? HTTPURLResponse)?.statusCode)
        }
        if let landing = Self.subscribeRedirectLanding(requested: url, response: http) {
            throw FetchError.subscribeRedirect(landedOn: landing)
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

    /// The interstitial a request LANDED on when the site redirected it there, or nil
    /// when the response is the page we asked for. Pure (takes the response's final
    /// URL, not the network) so the whole policy is unit-testable.
    ///
    /// Fires only on a genuine substitution: the final URL differs from the requested
    /// one AND is a subscribe / sign-in / cookie-check interstitial
    /// (`NewsAggregatorUnwrapper.isInterstitialURL`) AND the request wasn't for an
    /// interstitial in the first place — so deliberately saving a subscribe page, or
    /// replaying an archived one, still fetches normally.
    static func subscribeRedirectLanding(requested: URL, response: HTTPURLResponse) -> URL? {
        subscribeRedirectLanding(requested: requested, finalURL: response.url)
    }

    /// Testable core of `subscribeRedirectLanding(requested:response:)`.
    public static func subscribeRedirectLanding(requested: URL, finalURL: URL?) -> URL? {
        guard let finalURL, finalURL != requested,
              NewsAggregatorUnwrapper.isInterstitialURL(finalURL),
              !NewsAggregatorUnwrapper.isInterstitialURL(requested)
        else { return nil }
        return finalURL
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
