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
/// This enum is the home of the pure, well-tested wrapper parsers
/// (`facebookRedirectTarget`, `googleNewsArticleID`/`googleNewsURL`/
/// `googleNewsBatchExecute`, `appleNewsPublisherURL`, `resolveFinalRedirect`,
/// `fetchText`). The app-wide unwrap dispatch lives in `URLUnwrapper`, whose
/// `[WrapperHandler]` registry wraps these parsers; every surface unwraps through
/// `URLUnwrapper` (offline-first, tracking-stripped).
public enum NewsAggregatorUnwrapper {

    // MARK: - Host classification

    /// Apple News articles are shared from both `apple.news` and the Stocks app's
    /// web landing host. Both return the publisher URL in their HTML's delayed
    /// redirect call; the delay is only for browsers and is never needed here.
    public static func isAppleNews(_ host: String) -> Bool {
        HostMatching.hostSuffixMatches(host, "apple.news") || host == "stocks.apple.com"
    }

    public static func isGoogleNews(_ host: String) -> Bool {
        host == "news.google.com" || host == "news.url.google.com"
    }

    // MARK: - Apple News

    /// Pure (no I/O) so it's unit-testable. The Apple News web page redirects to the
    /// publisher via a `redirectToUrlAfterTimeout("<publisher url>")` JS call — the
    /// one reliable place the original URL appears (its `og:url`/canonical point at
    /// apple.news itself). Returns nil for News+ exclusives, which carry no such URL.
    public static func appleNewsPublisherURL(inHTML html: String) -> URL? {
        guard let match = firstMatch(in: html, pattern: #"redirectToUrlAfterTimeout\(\s*["']([^"']+)["']"#),
              let url = URL(string: match.removingPercentEncoding ?? match),
              let host = url.host?.lowercased(), !isAppleNews(host), url.scheme?.hasPrefix("http") == true
        else { return nil }
        return url
    }

    // MARK: - Google News

    /// The opaque article id from a Google News URL: the path segment after
    /// `articles`/`read` (handles `/rss/articles/<id>`, `/articles/<id>`,
    /// `/read/<id>`). Pure.
    public static func googleNewsArticleID(from url: URL) -> String? {
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
    public static func googleNewsURL(fromArticleID id: String) -> URL? {
        guard let data = base64URLDecode(id) else { return nil }
        return firstEmbeddedHTTPURL(in: data)
    }

    /// Best-effort decode of a new-style Google News id via Google's internal
    /// `batchexecute` RPC: fetch the article page for its signature + timestamp,
    /// then POST them back to get the real URL. Fragile by nature (undocumented
    /// internal API) — any deviation returns nil and the caller falls back. Internal
    /// (not private) so `URLUnwrapper`'s Google News handler reuses it.
    public static func googleNewsBatchExecute(articleID: String, session: URLSession) async -> URL? {
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
        request.setValue(WebFetchConstants.safariUserAgent, forHTTPHeaderField: "User-Agent")
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
    public static func googleBatchExecuteURL(fromResponse text: String) -> URL? {
        guard let urlString = firstMatch(
                in: text, pattern: #"garturlres\\?",\\?"(https?:[^"\\]+)"#),
              let url = URL(string: urlString)
        else { return nil }
        return url
    }

    // MARK: - Redirect shorteners

    /// Follows `url`'s HTTP redirects and returns the final URL — but only if it
    /// actually left the shortener's host. Prefer HEAD so no body is downloaded, but
    /// retry with a one-kilobyte GET range when a service rejects HEAD. Amazon's
    /// `amzn.asia` links are one such service: a HEAD returns 404 while a GET returns
    /// the real regional storefront redirect. Internal (not private) so
    /// `URLUnwrapper`'s shortener handler reuses it.
    public static func resolveFinalRedirect(_ url: URL, session: URLSession) async -> URL? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "HEAD"
        request.setValue(WebFetchConstants.safariUserAgent, forHTTPHeaderField: "User-Agent")
        if let final = await finalRedirect(for: request, originalHost: url.host, session: session) { return final }

        request.httpMethod = "GET"
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        return await finalRedirect(for: request, originalHost: url.host, session: session)
    }

    /// Follows `url`'s HTTP redirects with a GET (never HEAD) and returns the final URL
    /// once it leaves `url`'s host. Some share interstitials emit their later redirect
    /// hops only on a full GET — Google's `share.google` link first 302s to an
    /// on-Google interstitial that 301s onward only under GET, so a HEAD-first follow
    /// stops one hop short. A 1 KB range cap keeps the final body tiny: only the
    /// resolved URL is read, and the page is re-fetched downstream for classification.
    /// Internal so `URLUnwrapper`'s share handler can reuse it.
    public static func resolveFinalRedirectViaGET(_ url: URL, session: URLSession) async -> URL? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "GET"
        request.setValue(WebFetchConstants.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        return await finalRedirect(for: request, originalHost: url.host, session: session)
    }

    private static func finalRedirect(
        for request: URLRequest, originalHost: String?, session: URLSession
    ) async -> URL? {
        guard let (_, response) = try? await session.data(for: request),
              let final = response.url,
              let scheme = final.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let finalHost = final.host?.lowercased(),
              finalHost != originalHost?.lowercased()
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
    public static func facebookRedirectTarget(_ url: URL) -> URL? {
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
        HostMatching.hostSuffixMatches(host, "facebook.com") || host == "fb.com"
    }

    // MARK: - Publisher subscribe / cookie-check interstitials

    /// Query params publishers use to carry the page a subscribe / sign-in /
    /// cookie-check interstitial is holding hostage. `dest` is News Corp's
    /// (`theaustralian.com.au`, `heraldsun.com.au`, `dailytelegraph.com.au`,
    /// `couriermail.com.au`, `news.com.au`, …); `url` is the same family's
    /// `/remote/check_cookie.html` bounce; the rest are the conventional names.
    private static let interstitialTargetParams = [
        "dest", "destination", "returnurl", "return_url", "return", "redirect",
        "redirecturl", "redirect_uri", "url", "next", "targeturl",
    ]

    /// Path shapes that mark a URL as an interstitial rather than content. Matched
    /// against whole, lowercased path segments (plus the `check_cookie.html` leaf),
    /// so an article whose slug merely CONTAINS one of these words is untouched.
    private static let interstitialPathSegments: Set<String> = [
        "subscribe", "subscribes", "subscription", "subscriptions", "paywall",
        "signin", "sign-in", "login", "log-in", "register", "checkout",
        "check_cookie.html",
    ]

    /// Extracts the real page from a publisher's own subscribe / sign-in /
    /// cookie-check interstitial, fully offline — the target travels inline in a
    /// query param. Shape (News Corp Australia, the case that motivated this):
    ///
    ///     https://www.theaustralian.com.au/subscribe/news/1/?sourceCode=…
    ///         &dest=https://www.theaustralian.com.au/wealth/…/news-story/<id>
    ///         &memtype=anonymous&mode=premium
    ///
    /// A paywalled article on those sites REDIRECTS to this URL, so it is what
    /// Safari's address bar shows and what a share/copy hands us. Left wrapped it
    /// poisons everything downstream: extraction reads the subscription pitch as
    /// the body, dedupe keys every locked article on the same interstitial path,
    /// and the archive reader asks archive.today for a URL it never snapshots.
    ///
    /// Deliberately conservative — this is the one handler whose matcher can't key
    /// on the host, so the PATH must prove the URL is an interstitial AND the
    /// target must be an absolute http(s) URL on the SAME site. That same-site rule
    /// is what keeps this from becoming a general open-redirect follower: an
    /// attacker's `?dest=` can only ever point back into the publisher's own
    /// domain. Returns nil (caller keeps the original URL) when the target is
    /// itself an interstitial, so a self-referential `dest=` can't loop. Pure.
    public static func interstitialTarget(_ url: URL) -> URL? {
        guard url.scheme?.lowercased().hasPrefix("http") == true,
              let host = url.host?.lowercased(),
              isInterstitialPath(url),
              let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        else { return nil }

        for name in interstitialTargetParams {
            guard let raw = queryItems.first(where: { $0.name.lowercased() == name })?.value,
                  let target = URL(string: raw),
                  target.scheme?.lowercased().hasPrefix("http") == true,
                  let targetHost = target.host?.lowercased(),
                  isSameSite(targetHost, host),
                  !isInterstitialPath(target)
            else { continue }
            return target
        }
        return nil
    }

    /// True when `url` is a publisher's subscribe / sign-in / cookie-check
    /// interstitial rather than content — judged by its PATH alone (whole segments),
    /// so it holds for the bare interstitial that carries no `dest=` target.
    ///
    /// The fetch layer needs exactly this question, separately from
    /// `interstitialTarget`: a paywalled article REDIRECTS to the interstitial, so a
    /// plain GET of the article silently returns the subscription pitch, and HTML
    /// that long and that free of gate wording reads as a perfectly good article
    /// body. Recognizing the landing page is what lets that fetch fail instead
    /// (`ArticleFetcher.FetchError.subscribeRedirect`).
    public static func isInterstitialURL(_ url: URL) -> Bool {
        isInterstitialPath(url)
    }

    /// True when any whole path segment of `url` is an interstitial marker.
    private static func isInterstitialPath(_ url: URL) -> Bool {
        url.path.split(separator: "/").contains {
            interstitialPathSegments.contains($0.lowercased())
        }
    }

    /// Same-site in either direction (`www.x.com` ↔ `x.com`, `x.com` ↔
    /// `myaccount.x.com`), by comparing `www.`-stripped hosts for equality or a
    /// subdomain relationship. Deliberately not a public-suffix parse: the only
    /// question here is whether an interstitial is handing us back a page on its
    /// own site, and both hosts come from the same URL family.
    private static func isSameSite(_ target: String, _ wrapper: String) -> Bool {
        let target = HostMatching.normalizedHost(target)
        let wrapper = HostMatching.normalizedHost(wrapper)
        return target == wrapper
            || HostMatching.hostSuffixMatches(target, wrapper)
            || HostMatching.hostSuffixMatches(wrapper, target)
    }

    // MARK: - Helpers

    /// First capture group of `pattern` in `text`, or nil.
    public static func firstMatch(in text: String, pattern: String) -> String? {
        RegexCapture.first(in: text, pattern: pattern)
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
    public static func firstEmbeddedHTTPURL(in data: Data) -> URL? {
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

    /// GETs `url` and returns its decoded HTML text (capped at `maxBytes`), or nil
    /// on a non-2xx / oversized / undecodable response. Internal (not private) so
    /// `URLUnwrapper`'s Apple News handler reuses it.
    public static func fetchText(_ url: URL, session: URLSession) async -> String? {
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(WebFetchConstants.safariUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= WebFetchConstants.maxBytes
        else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }
}
