//
//  HostSuffixLookup.swift
//  LunaPaywallBypass
//

import Foundation

/// Resolves a URL's host against a table keyed by registrable domain: `www.wsj.com`
/// and `edition.wsj.com` must both find the `wsj.com` entry. Shared by the unlock-rule
/// table, the no-fix denylist and the crawler-identity ladder so the three cannot
/// disagree about which hosts an entry covers.
enum HostSuffixLookup {

    /// `url`'s host and then each parent domain down to two labels, most specific
    /// first. Empty when the URL carries no host.
    static func candidateKeys(for url: URL) -> [String] {
        guard let host = url.host?.lowercased() else { return [] }
        var labels = host.split(separator: ".").map(String.init)
        var keys = [host]
        while labels.count > 2 {
            labels.removeFirst()
            keys.append(labels.joined(separator: "."))
        }
        return keys
    }

    /// The most specific value in `table` covering `url`'s host, or nil.
    static func value<Value>(for url: URL, in table: [String: Value]) -> Value? {
        candidateKeys(for: url).lazy.compactMap { table[$0] }.first
    }

    /// Whether any key covering `url`'s host is in `set`.
    static func contains(_ url: URL, in set: Set<String>) -> Bool {
        candidateKeys(for: url).contains { set.contains($0) }
    }
}
