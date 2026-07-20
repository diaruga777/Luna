//
//  HostMatching.swift
//  ReaderKit
//

import Foundation

/// The shared "does this host equal or have this domain as a subdomain" idiom,
/// used identically by `KnownSite`, `PlatformRecognizer`, `NewsAggregatorUnwrapper`,
/// `URLUnwrapper`, `SocialPostFinder`, and `BypassRuleTable`. Callers pass an
/// already-lowercased host; `domain`/`domains` are expected lowercased too.
public enum HostMatching {

    /// True when `host` equals `domain` or is one of its subdomains
    /// (`sub.domain` — matched via the leading-dot suffix, so `notdomain.com`
    /// never falsely matches `domain.com`).
    public static func hostSuffixMatches(_ host: String, _ domain: String) -> Bool {
        host == domain || host.hasSuffix(".\(domain)")
    }

    /// True when `host` matches ANY of `domains` by `hostSuffixMatches`.
    public static func hostSuffixMatches(_ host: String, anyOf domains: some Sequence<String>) -> Bool {
        domains.contains { hostSuffixMatches(host, $0) }
    }

    /// `host`, lowercased with a leading `www.` stripped, for loose cross-URL
    /// equality (dedup / suggestion matching) where a `www.` subdomain should
    /// collapse to the same key as the bare host. Path/query/fragment untouched.
    public static func normalizedHost(_ host: String) -> String {
        var normalized = host.lowercased()
        if normalized.hasPrefix("www.") { normalized.removeFirst(4) }
        return normalized
    }

    /// `path` with one trailing slash removed, unless `path` is just `"/"` (kept as
    /// the caller passed it — collapsing it to `""` would make a bare-host URL
    /// indistinguishable from an empty path in a host+path dedup key). Used
    /// alongside `normalizedHost` to build a loose cross-URL equality key.
    public static func normalizedPath(_ path: String) -> String {
        guard path.count > 1, path.hasSuffix("/") else { return path }
        var normalized = path
        normalized.removeLast()
        return normalized
    }
}
