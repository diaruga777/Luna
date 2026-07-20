//
//  SiteUnlockRules.swift
//  LunaPaywallBypass
//

import Foundation

/// One site's paywall-unlock config, produced by `scripts/generate_site_rules.js`
/// into the bundled `site_unlock_rules.json`. Every field is optional; a nil field
/// means "this technique isn't used for this site". Group configs are already
/// flattened to one rule per member domain, and `{domain}` placeholders in the
/// regexes are already substituted.
///
/// `csCode` (a small nested cleanup DSL used by a few sites) is carried in the
/// JSON but not decoded here — it belongs to the browser tier. `ldJsonUrl` is
/// decoded but not yet consumed (needs a second network fetch to resolve).
public struct SiteUnlockRule: Decodable, Equatable {
    public let domain: String
    /// Keep cookies (the default is to blank the `Cookie:` request header).
    public let allowCookies: Bool?
    /// Regex sources whose matching script/XHR requests should be blocked (the
    /// metering/paywall vendor scripts). Delimiter-free source strings.
    public let blockRegex: [String]?
    /// Inline-script block pattern (paywall logic inlined into the page).
    public let blockJsInline: String?
    /// A named crawler UA to spoof: `googlebot` (also adds Google referer + XFF),
    /// `bingbot`, or `facebookbot`.
    public let useragent: String?
    /// An arbitrary custom User-Agent string.
    public let useragentCustom: String?
    /// A named referer origin (`google`).
    public let referer: String?
    /// A custom `Referer` value (e.g. a site that unlocks for a specific referrer).
    public let refererCustom: String?
    /// Extra request headers to set.
    public let headersCustom: [String: String]?
    /// Spoof `X-Forwarded-For` from a region (`eu`) or a random IP (any other value).
    public let randomIP: String?
    /// Delete all stored cookies for the site after load.
    public let removeCookies: Bool?
    /// Delete only these named cookies (the meter counters).
    public let removeCookiesSelectDrop: [String]?
    /// Keep only these named cookies, drop the rest.
    public let removeCookiesSelectHold: [String]?
    /// Clear localStorage/sessionStorage (client-side meter store).
    public let clearLocalStorage: Bool?
    /// Sanitize/reveal the article in the browser tier.
    public let csDompurify: Bool?
    /// Reconstruct the body from JSON-LD (`paywallSelector|bodySelector[|append][|hold]`).
    public let ldJson: String?
    /// Reconstruct from `__NEXT_DATA__`.
    public let ldJsonNext: String?
    /// Reconstruct from an inline `<script>` JSON blob.
    public let ldJsonSource: String?
    /// Reconstruct from an external JSON/REST endpoint (needs a second fetch).
    public let ldJsonUrl: String?
    /// Reveal AMP subscriber sections in place.
    public let ampUnhide: Bool?
    /// Redirect to an AMP URL (template with `{path}`/`{host}`), or nil.
    public let ampRedirect: String?
}

/// A global paywall-vendor script blocker: its script/XHR requests are blocked on
/// ALL sites except `excludedDomains`.
public struct VendorScriptBlocker: Decodable, Equatable {
    public let blockRegex: String
    public let excludedDomains: [String]
}

/// Loads and indexes the bundled site paywall-unlock rule table. Both the silent
/// header/cookie tier and the WKWebView browser tier are driven from here.
public enum SiteUnlockRules {

    private struct File: Decodable {
        let rules: [SiteUnlockRule]
        let generalBlockers: [VendorScriptBlocker]
        let noFix: [String]
    }

    private static let file: File = {
        guard let url = Bundle.module.url(forResource: "site_unlock_rules", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(File.self, from: data)
        else { return File(rules: [], generalBlockers: [], noFix: []) }
        return decoded
    }()

    private static let byDomain: [String: SiteUnlockRule] =
        Dictionary(file.rules.map { ($0.domain, $0) }, uniquingKeysWith: { first, _ in first })

    private static let noFixSet: Set<String> = Set(file.noFix)

    /// The unlock rule for `url`'s host — an exact host match, else the nearest
    /// registrable-suffix match (so `www.wsj.com` and `edition.wsj.com` resolve to
    /// the `wsj.com` rule): host `==` domain OR host ends with `.`+domain. Nil when
    /// the site has no rule.
    public static func rule(for url: URL) -> SiteUnlockRule? {
        guard let host = url.host?.lowercased() else { return nil }
        if let rule = byDomain[host] { return rule }
        var labels = host.split(separator: ".").map(String.init)
        while labels.count > 2 {
            labels.removeFirst()
            if let rule = byDomain[labels.joined(separator: ".")] { return rule }
        }
        return nil
    }

    /// The global vendor-script block patterns (applied to every site except each
    /// entry's `excludedDomains`).
    public static var generalBlockers: [VendorScriptBlocker] { file.generalBlockers }

    /// True when the host is on the known-unfixable denylist, so we shouldn't waste a
    /// bypass attempt on it.
    public static func isNoFix(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if noFixSet.contains(host) { return true }
        var labels = host.split(separator: ".").map(String.init)
        while labels.count > 2 {
            labels.removeFirst()
            if noFixSet.contains(labels.joined(separator: ".")) { return true }
        }
        return false
    }

    /// Total loaded rule count (diagnostics/tests).
    public static var ruleCount: Int { file.rules.count }
}
