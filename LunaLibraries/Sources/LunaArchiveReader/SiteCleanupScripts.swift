//
//  SiteCleanupScripts.swift
//  ReaderKit
//

import Foundation
import WebKit

/// Per-site bespoke DOM-cleanup snippets injected by the browser tier (alongside the
/// generic `PaywallUnlockRules` cleanup) when the paywall-unlock toggle is on. Each is
/// a self-contained JavaScript IIFE (no extension APIs, no cross-origin fetch beyond
/// the page's own origin) that reveals a specific site's article — removing that site's
/// overlay, stripping the classes/attributes it uses to clamp the body, reconstructing
/// the body from embedded JSON (`__NEXT_DATA__` / Fusion / Redux state / inline
/// bootstraps), un-lazying images, etc. Only iOS-feasible DOM operations are ported;
/// site logic whose sole mechanism is a cross-origin/extension fetch is omitted (the
/// generic cleanup + the content blocker still apply, and archive.today remains the
/// terminal fallback).
///
/// The snippets are bundled as `site_cleanup_scripts.json` (a list of
/// `{domains, js}` entries) so the set can scale to hundreds of sites across the
/// English + European news markets.
public enum SiteCleanupScripts {

    private struct Entry: Decodable {
        let domains: [String]
        let js: String
    }

    private static let byDomain: [String: String] = {
        guard let url = Bundle.module.url(forResource: "site_cleanup_scripts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [:] }
        var map: [String: String] = [:]
        for entry in entries {
            for domain in entry.domains where map[domain] == nil {
                map[domain] = entry.js
            }
        }
        return map
    }()

    /// The bespoke cleanup snippet for `url`'s host (exact or registrable-suffix
    /// match), or nil when the site has no per-site snippet.
    public static func script(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if let snippet = byDomain[host] { return snippet }
        var labels = host.split(separator: ".").map(String.init)
        while labels.count > 2 {
            labels.removeFirst()
            if let snippet = byDomain[labels.joined(separator: ".")] { return snippet }
        }
        return nil
    }

    /// A `WKUserScript` (documentEnd, main frame) for `url`, or nil.
    public static func userScript(for url: URL) -> WKUserScript? {
        guard let source = script(for: url) else { return nil }
        return WKUserScript(source: source, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
    }

    /// Number of distinct domains with a bespoke snippet (diagnostics/tests).
    public static var count: Int { byDomain.count }
}
