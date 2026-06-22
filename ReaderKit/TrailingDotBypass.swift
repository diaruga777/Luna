//
//  TrailingDotBypass.swift
//  ReaderKit
//

import Foundation
import ClipPaywallBypass

/// Paywall bypass via the "trailing dot" trick: appending a dot to the host
/// (`www.nytimes.com` → `www.nytimes.com.`) yields a fully-qualified domain the
/// browser treats as a distinct origin, so a site's host-keyed paywall
/// JS/cookies/meter don't apply — yet the server still returns the full article
/// (same cert, same content, HTTP 200). Confirmed on NYT and reported to work on
/// other client-side cookie/origin-keyed meters; spotty, so it's a *cheap try*,
/// never a guarantee. The transform is publisher-agnostic — `BypassStrategySelector`
/// decides *when* to apply it (per-host rule or the generic metered branch), so the
/// transform no longer gates on host.
enum TrailingDotBypass {

    /// The trailing-dot variant of an article URL (`host` → `host.`), preserving the
    /// path and query, or nil when the host is missing/empty, already carries a
    /// trailing dot, or the transform is a no-op.
    static func trailingDotURL(for url: URL) -> URL? {
        PaywallBypassRules.trailingDotURL(for: url)
    }

    /// Whether `host` is a New York Times property (the apex, any subdomain, or the
    /// `nyt.com` alias). Retained for the per-host rule table / callers that still
    /// reason about NYT specifically. A trailing dot is tolerated (idempotent).
    static func isNYTHost(_ host: String) -> Bool {
        PaywallBypassRules.isNYTHost(host)
    }
}
