//
//  TrailingDotBypass.swift
//  ReaderKit
//

import Foundation

/// Paywall bypass via the "trailing dot" trick: appending a dot to the host
/// (`www.nytimes.com` → `www.nytimes.com.`) yields a fully-qualified domain the
/// browser treats as a distinct origin, so a site's host-keyed paywall
/// JS/cookies/meter don't apply — yet the server still returns the full article
/// (same cert, same content, HTTP 200). Confirmed on NYT and reported to work on
/// other client-side cookie/origin-keyed meters; spotty, so it's a *cheap try*,
/// never a guarantee. The transform itself is publisher-agnostic —
/// `BypassStrategySelector` decides *when* to apply it (per-host rule or the generic
/// metered branch), not this type.
public enum TrailingDotBypass {

    /// The trailing-dot variant of an article URL (`host` → `host.`), preserving the
    /// path and query, or nil when the host is missing/empty, already carries a
    /// trailing dot, or the transform is a no-op.
    public static func trailingDotURL(for url: URL) -> URL? {
        guard let host = url.host, !host.isEmpty, !host.hasSuffix(".") else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.host = host + "."
        return components?.url
    }

    /// Whether `host` is a New York Times property (the apex, any subdomain, or the
    /// `nyt.com` alias). Used by the per-host rule table and other callers that reason
    /// about NYT specifically. A trailing dot is tolerated (idempotent).
    public static func isNYTHost(_ host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return host == "nytimes.com" || host.hasSuffix(".nytimes.com")
            || host == "nyt.com" || host.hasSuffix(".nyt.com")
    }
}
