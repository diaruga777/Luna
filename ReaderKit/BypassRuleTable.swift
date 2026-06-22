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

    static let rules = [
        "nytimes.com", "wsj.com", "ft.com", "economist.com", "barrons.com",
        "bloomberg.com", "haaretz.com", "washingtonpost.com", "newyorker.com",
        "theatlantic.com", "wired.com", "businessinsider.com", "telegraph.co.uk",
        "thetimes.co.uk", "latimes.com", "bostonglobe.com", "nikkei.com",
        "seekingalpha.com", "hbr.org", "theinformation.com", "foreignpolicy.com",
        "foreignaffairs.com",
    ].map { BypassRule(domain: $0, strategies: [.archiveToday]) }
}
