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
public enum URLCanonicalizer {

    /// Drops the fragment and known tracking params from `url`. Real query params are
    /// kept so distinct articles still resolve to distinct URLs. The tracking-param
    /// list itself lives once in `URLClassification.canonicalURL` (the SPM module both
    /// the app and extensions share), so there is a single source of truth.
    public static func strip(_ url: URL) -> URL {
        URLClassification.canonicalURL(url)
    }
}
