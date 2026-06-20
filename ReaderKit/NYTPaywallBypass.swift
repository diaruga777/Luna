//
//  NYTPaywallBypass.swift
//  ReaderKit
//

import Foundation

/// New York Times paywall bypass via the "trailing dot" trick: appending a dot to
/// the host (`www.nytimes.com` → `www.nytimes.com.`) yields a fully-qualified
/// domain the browser treats as a distinct origin, so NYT's host-keyed paywall
/// JS/cookies/meter don't apply — yet the server still returns the full article
/// (same cert, same content). The archive reader tries this dotted URL in its
/// WKWebView FIRST and only falls back to archive.today if it doesn't yield a
/// readable article.
enum NYTPaywallBypass {

    /// The trailing-dot variant of a NYT article URL to try before archive.today,
    /// or nil when `url` isn't a NYT host (or already carries a trailing dot).
    static func trailingDotURL(for url: URL) -> URL? {
        guard let host = url.host?.lowercased(), !host.hasSuffix("."), isNYTHost(host),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        components.host = host + "."
        guard let dotted = components.url, dotted.absoluteString != url.absoluteString else { return nil }
        return dotted
    }

    /// Whether `host` is a New York Times property (the apex, any subdomain, or the
    /// `nyt.com` alias). A trailing dot is tolerated so the check is idempotent.
    static func isNYTHost(_ host: String) -> Bool {
        let bare = host.hasSuffix(".") ? String(host.dropLast()) : host
        let nytDomains = ["nytimes.com", "nyt.com"]
        return nytDomains.contains { bare == $0 || bare.hasSuffix("." + $0) }
    }
}
