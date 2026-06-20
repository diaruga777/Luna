//
//  NewsAggregatorUnwrapper.swift
//  ReaderKit
//

import Foundation

/// Unwraps a news-aggregator "wrapper" URL — Apple News (`apple.news`), Google
/// News (`news.google.com`), and common link shorteners — to the underlying
/// publisher article URL, so the rest of the pipeline (extraction, the
/// archive.today reader, the list row, sharing) operates on the real article.
/// A wrapper URL breaks both text extraction (the aggregator page is a JS shell,
/// not the article) and the archive flow (archive.today can't snapshot it), so we
/// resolve it up front and continue as if the publisher URL had been saved.
///
/// `unwrap` returns nil for any non-wrapper URL (after a cheap host check, no
/// network) and for wrappers with no recoverable underlying URL (e.g. an Apple
/// News+ exclusive) — callers then proceed with the original URL unchanged.
enum NewsAggregatorUnwrapper {

    /// Resolves `url` to its underlying publisher URL, or nil. Network-backed only
    /// for recognized wrapper hosts; every other host returns nil immediately.
    static func unwrap(_ url: URL, session: URLSession = .shared) async -> URL? {
        // Facebook redirect/share links carry the target inline (offline, no
        // network) and an `fbrpc://` deep link has no http host, so this runs
        // BEFORE the host gate below.
        if let target = facebookRedirectTarget(url) { return target }
        guard let host = url.host?.lowercased() else { return nil }
        if isAppleNews(host) { return await unwrapAppleNews(url, session: session) }
        if isGoogleNews(host) { return await unwrapGoogleNews(url, session: session) }
        if redirectShorteners.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return await resolveFinalRedirect(url, session: session)
        }
        return nil
    }

    /// Normalizes a raw incoming URL/string at a SAVE ENTRY POINT, before any
    /// `hasPrefix("http")` gate. A Facebook deep link (`fbrpc://…&target_url=…`)
    /// carries its real http(s) article inline but has no http scheme, so the
    /// plain http gates at the share/action extensions, the in-app "Save a Link"
    /// alert, and the app intents would otherwise drop it (or, in the alert,
    /// mangle it into `https://fbrpc://…`). This applies the offline Facebook
    /// unwrap up front and returns the http target when present, else the original
    /// URL unchanged. Pure (no network) — the async `unwrap` in `ingest` still
    /// handles apple.news / google / shortener cases later.
    static func normalizedIncomingURL(_ url: URL) -> URL {
        facebookRedirectTarget(url) ?? url
    }

    /// String overload of `normalizedIncomingURL(_:)` for entry points that hold a
    /// raw string (the in-app "Save a Link" alert, app intents). Returns the http
    /// target's string when the input is a Facebook deep link, else the original
    /// string unchanged (so a non-URL string is left for the caller's own gate).
    static func normalizedIncomingURLString(_ string: String) -> String {
        guard let url = URL(string: string), let target = facebookRedirectTarget(url) else {
            return string
        }
        return target.absoluteString
    }

    // MARK: - Host classification

    static func isAppleNews(_ host: String) -> Bool {
        host == "apple.news" || host.hasSuffix(".apple.news")
    }

    static func isGoogleNews(_ host: String) -> Bool {
        host == "news.google.com" || host == "news.url.google.com"
    }

    /// Link shorteners / aggregators that wrap an article behind a plain HTTP
    /// redirect (so following it yields the publisher URL). News-relevant set —
    /// deliberately NOT a generic "follow every link" so ordinary URLs are
    /// untouched. Several (`nyti.ms`, `wapo.st`, `on.ft.com`, `econ.st`) resolve to
    /// hard-paywall hosts, which then correctly route to the archive reader.
    private static let redirectShorteners: Set<String> = [
        "flip.it", "trib.al", "t.co", "bit.ly", "buff.ly", "apple.co",
        "nyti.ms", "wapo.st", "on.ft.com", "econ.st", "reut.rs",
        "cnn.it", "bbc.in", "nbcnews.to", "abcn.ws", "cbsn.ws",
    ]

    // MARK: - Apple News

    private static func unwrapAppleNews(_ url: URL, session: URLSession) async -> URL? {
        guard let html = await fetchText(url, session: session) else { return nil }
        return appleNewsPublisherURL(inHTML: html)
    }

    /// Pure (no I/O) so it's unit-testable. The Apple News web page redirects to the
    /// publisher via a `redirectToUrlAfterTimeout("<publisher url>")` JS call — the
    /// one reliable place the original URL appears (its `og:url`/canonical point at
    /// apple.news itself). Returns nil for News+ exclusives, which carry no such URL.
    static func appleNewsPublisherURL(inHTML html: String) -> URL? {
        guard let match = firstMatch(in: html, pattern: #"redirectToUrlAfterTimeout\(\s*["']([^"']+)["']"#),
              let url = URL(string: match.removingPercentEncoding ?? match),
              let host = url.host?.lowercased(), !isAppleNews(host), url.scheme?.hasPrefix("http") == true
        else { return nil }
        return url
    }

    // MARK: - Google News

    private static func unwrapGoogleNews(_ url: URL, session: URLSession) async -> URL? {
        guard let articleID = googleNewsArticleID(from: url) else { return nil }
        // Classic `CBMi…` ids embed the publisher URL directly (offline-decodable).
        if let offline = googleNewsURL(fromArticleID: articleID) { return offline }
        // New-style ids (mid-2024+) need Google's batchexecute round-trip.
        return await googleNewsBatchExecute(articleID: articleID, session: session)
    }

    /// The opaque article id from a Google News URL: the path segment after
    /// `articles`/`read` (handles `/rss/articles/<id>`, `/articles/<id>`,
    /// `/read/<id>`). Pure.
    static func googleNewsArticleID(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let marker = parts.lastIndex(where: { $0 == "articles" || $0 == "read" }),
              marker + 1 < parts.count else { return nil }
        let id = parts[marker + 1]
        return id.isEmpty ? nil : id
    }

    /// Decodes a classic Google News article id offline: the id is URL-safe base64
    /// of a protobuf blob that embeds the publisher URL as a plain substring
    /// (between a short length prefix and a `0xd2 0x01 0x00` suffix). New-style ids
    /// (the blob holds only an internal id + signature) return nil. Pure.
    static func googleNewsURL(fromArticleID id: String) -> URL? {
        guard let data = base64URLDecode(id) else { return nil }
        return firstEmbeddedHTTPURL(in: data)
    }

    /// Best-effort decode of a new-style Google News id via Google's internal
    /// `batchexecute` RPC: fetch the article page for its signature + timestamp,
    /// then POST them back to get the real URL. Fragile by nature (undocumented
    /// internal API) — any deviation returns nil and the caller falls back.
    private static func googleNewsBatchExecute(articleID: String, session: URLSession) async -> URL? {
        guard let pageURL = URL(string: "https://news.google.com/rss/articles/\(articleID)"),
              let html = await fetchText(pageURL, session: session),
              let signature = firstMatch(in: html, pattern: #"data-n-a-sg="([^"]+)""#),
              let timestamp = firstMatch(in: html, pattern: #"data-n-a-ts="([^"]+)""#)
        else { return nil }

        let inner = "[\"garturlreq\",[[\"X\",\"X\",[\"X\",\"X\"],null,null,1,1,\"US:en\",null,1,null,"
            + "null,null,null,null,0,1],\"X\",\"X\",1,[1,1,1],1,1,null,0,0,null,0],"
            + "\"\(articleID)\",\(timestamp),\"\(signature)\"]"
        let fReq = [[["Fbv4je", inner]]]
        guard let fReqData = try? JSONSerialization.data(withJSONObject: fReq),
              let fReqString = String(data: fReqData, encoding: .utf8),
              let endpoint = URL(string: "https://news.google.com/_/DotsSplashUi/data/batchexecute")
        else { return nil }

        var request = URLRequest(url: endpoint, timeoutInterval: 12)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded;charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "f.req", value: fReqString)]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return Self.googleBatchExecuteURL(fromResponse: text)
    }

    /// Parses the publisher URL out of a Google `batchexecute` response. The body is
    /// an anti-JSON-hijacking-prefixed, length-chunked envelope that embeds the
    /// payload `["garturlres","<url>",…]` as an escaped JSON string. Rather than
    /// slice the fragile chunk framing, grab the URL right after the `garturlres`
    /// marker (quotes optionally backslash-escaped). Pure, so it's testable.
    static func googleBatchExecuteURL(fromResponse text: String) -> URL? {
        guard let urlString = firstMatch(
                in: text, pattern: #"garturlres\\?",\\?"(https?:[^"\\]+)"#),
              let url = URL(string: urlString)
        else { return nil }
        return url
    }

    // MARK: - Redirect shorteners

    /// Follows `url`'s HTTP redirects (HEAD, so no body is downloaded) and returns
    /// the final URL — but only if it actually left the shortener's host.
    private static func resolveFinalRedirect(_ url: URL, session: URLSession) async -> URL? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await session.data(for: request),
              let final = response.url, let finalHost = final.host?.lowercased(),
              finalHost != url.host?.lowercased()
        else { return nil }
        return final
    }

    // MARK: - Facebook redirect / share links

    /// Extracts the underlying article URL from a Facebook redirect wrapper,
    /// fully offline (the target travels inline in a query param). Handles two
    /// shapes:
    ///   - `fbrpc://…/f?…&target_url=<percent-encoded-url>&…` deep links (shared
    ///     out of the Facebook app), reading `target_url`.
    ///   - link-shim URLs `https://l.facebook.com/l.php?u=<percent-encoded-url>&…`
    ///     (and `lm.`/`m.`/bare `facebook.com` + `/l.php`), reading `u`.
    /// The embedded value is percent-decoded once (URLComponents already decodes
    /// query values), and the result is returned only if it is an http(s) URL on
    /// a non-Facebook host. Returns nil for anything else. Pure.
    static func facebookRedirectTarget(_ url: URL) -> URL? {
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased()

        let paramName: String
        if scheme == "fbrpc" {
            paramName = "target_url"
        } else if scheme == "https" || scheme == "http",
                  let host, isFacebookLinkShimHost(host),
                  url.path.lowercased() == "/l.php" {
            paramName = "u"
        } else {
            return nil
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = components.queryItems?.first(where: { $0.name == paramName })?.value,
              let target = URL(string: raw),
              target.scheme?.lowercased().hasPrefix("http") == true,
              let targetHost = target.host?.lowercased(), !isFacebookHost(targetHost)
        else { return nil }
        return target
    }

    /// Hosts that serve Facebook's `/l.php` link shim.
    private static func isFacebookLinkShimHost(_ host: String) -> Bool {
        host == "l.facebook.com" || host == "lm.facebook.com"
            || host == "m.facebook.com" || host == "facebook.com" || host == "www.facebook.com"
    }

    /// Any Facebook-owned host (so we never "unwrap" to another Facebook URL).
    private static func isFacebookHost(_ host: String) -> Bool {
        host == "facebook.com" || host.hasSuffix(".facebook.com") || host == "fb.com"
    }

    // MARK: - Helpers

    /// First capture group of `pattern` in `text`, or nil.
    static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }

    /// URL-safe base64 decode (restores `+`/`/` and pads to a multiple of 4).
    static func base64URLDecode(_ string: String) -> Data? {
        var normalized = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 { normalized += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: normalized)
    }

    /// Scans decoded bytes for the first embedded `http(s)://…` URL, reading up to
    /// the first byte that can't belong to a URL (control char, the protobuf field
    /// separators, quotes, whitespace). The blob stores the URL as a raw substring.
    static func firstEmbeddedHTTPURL(in data: Data) -> URL? {
        // ISO-Latin-1 maps every byte to a scalar (never fails), so high bytes from
        // the surrounding protobuf framing become >0x7F scalars that end the scan.
        guard let ascii = String(data: data, encoding: .isoLatin1),
              let start = ascii.range(of: "https://")?.lowerBound
                ?? ascii.range(of: "http://")?.lowerBound
        else { return nil }
        let urlText = ascii[start...].prefix { character in
            guard character.unicodeScalars.count == 1,
                  let scalar = character.unicodeScalars.first else { return false }
            return scalar.value > 0x20 && scalar.value < 0x7F
                && character != "\"" && character != "<" && character != ">" && character != "\\"
        }
        return URL(string: String(urlText))
    }

    private static func fetchText(_ url: URL, session: URLSession) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= ArticleFetcher.maxBytes
        else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}
