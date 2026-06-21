//
//  URLCanonicalizer.swift
//  ReaderKit
//

import Foundation

/// The ONE place URL tracking-param stripping lives. `strip` drops the fragment and
/// the known tracking query params (utm_*, fbclid, …) while keeping real query
/// params, so distinct articles still resolve. Both the unwrap path
/// (`URLUnwrapper`) and the archive path (`ArticleFetcher.canonicalForArchiving`)
/// canonicalize through here, so dedupe / display / share / archive all agree on
/// one canonical URL from a single tracking-param list. Pure: no network, no UIKit.
enum URLCanonicalizer {

    /// Common tracking query params stripped so a canonical URL doesn't vary by the
    /// referral chain it arrived through. A stray fragment can't alter the archive
    /// path either, so it's dropped too.
    static let trackingParams: Set<String> = [
        "mod", "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "fbclid", "gclid", "igshid", "ref", "cmpid", "ocid", "spm", "smid",
    ]

    /// Drops the fragment and known tracking params from `url`. Real query params are
    /// kept so distinct articles still resolve to distinct URLs.
    static func strip(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.fragment = nil
        if let queryItems = components.queryItems {
            let kept = queryItems.filter { !trackingParams.contains($0.name.lowercased()) }
            components.queryItems = kept.isEmpty ? nil : kept
        }
        return components.url ?? url
    }
}
