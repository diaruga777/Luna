//
//  KnownSite.swift
//  ReaderKit
//

import LuneModels
import Foundation

/// One row of the deterministic, EXTENSIBLE site table mapping a host (and an
/// optional path predicate) to a `ContentKind`. Adding a site is a one-line append
/// to the relevant `…Sites` array — no control-flow edits, no detector changes.
///
/// `hosts` are matched host-suffix-wise (so `nytimes.com` matches `www.nytimes.com`
/// and any subdomain). An optional `path` predicate narrows the match to specific
/// path shapes (`/products/<slug>`, `/r/<sub>/comments/`). `kind` is a closure of
/// the URL so a row can pull an itemID (e.g. a platform row reuses the recognizer).
public struct KnownSite {
    /// Hosts matched exactly OR as a subdomain. Lowercased.
    public let hosts: [String]
    /// Optional path predicate over the path segments (leading "/" dropped). Nil ⇒
    /// the host alone decides.
    public let path: (([String]) -> Bool)?
    /// The kind a matching URL is, computed from the URL so the row can read an id.
    public let kind: (URL) -> ContentKind

    public init(hosts: [String], path: (([String]) -> Bool)? = nil, kind: @escaping (URL) -> ContentKind) {
        self.hosts = hosts
        self.path = path
        self.kind = kind
    }

    /// Whether `url` matches this row: a host-suffix hit AND (if present) the path
    /// predicate.
    public func matches(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              hosts.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else { return false }
        guard let path else { return true }
        return path(Array(url.pathComponents.dropFirst()))
    }
}
