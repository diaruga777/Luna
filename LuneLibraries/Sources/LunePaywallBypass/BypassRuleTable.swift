//
//  BypassRuleTable.swift
//  ReaderKit
//

import LuneURLClassification
import Foundation

/// A known paywall host. The table remains the source of host knowledge for
/// diagnostics and tests; the policy no longer varies by host.
public struct BypassRule: Equatable {
    public let domain: String
    public let strategies: [BypassStrategy]
}

/// Every supported paywall is handled through archive.is. There are intentionally
/// no third-party reader, proxy, or alternate archiver fallbacks here.
public enum BypassRuleTable {
    public static func rule(for url: URL) -> BypassRule? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasSuffix(".") { host.removeLast() }
        return rules.first { host == $0.domain || host.hasSuffix("." + $0.domain) }
    }

    /// Every hard-paywall host maps to the archive.is strategy. Built straight from
    /// `NewsSites.hardPaywall` so the bypass table can never drift from the
    /// classifier's notion of which hosts are hard-paywalled.
    public static let rules = NewsSites.hardPaywall
        .map { BypassRule(domain: $0, strategies: [.archiveToday]) }
}
