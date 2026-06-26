//
//  BypassRuleTable.swift
//  ReaderKit
//

import Foundation

/// A known paywall host. The table remains the source of host knowledge for
/// diagnostics and tests; the policy no longer varies by host.
struct BypassRule: Equatable {
    let domain: String
    let strategies: [BypassStrategy]
}

/// Every supported paywall is handled through archive.is. There are intentionally
/// no third-party reader, proxy, or alternate archiver fallbacks here.
enum BypassRuleTable {
    static func rule(for url: URL) -> BypassRule? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        return rules.first { host == $0.domain || host.hasSuffix("." + $0.domain) }
    }

    /// Every hard-paywall host maps to the archive.is strategy. Built straight from
    /// `NewsSites.hardPaywall` so the bypass table can never drift from the
    /// classifier's notion of which hosts are hard-paywalled.
    static let rules = NewsSites.hardPaywall
        .map { BypassRule(domain: $0, strategies: [.archiveToday]) }
}
