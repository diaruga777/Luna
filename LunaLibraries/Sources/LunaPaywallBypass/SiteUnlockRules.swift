//
//  SiteUnlockRules.swift
//  LunaPaywallBypass
//

import Foundation

/// A named crawler UA to spoof, or an arbitrary custom User-Agent string. A rule
/// carries at most one — the bundled table never sets both.
public enum UserAgentSpoof: Equatable {
    case crawler(CrawlerAgent)
    case custom(String)

    /// The named identity this spoof sends, matching a `custom` rule by its literal
    /// UA string — the bundled table spells one identity out longhand rather than
    /// naming it. Nil for a bespoke string no identity claims. Lets the
    /// identity ladder skip whatever a rule's own request leg is already spending.
    public var identity: CrawlerAgent? {
        switch self {
        case let .crawler(agent):
            return agent
        case let .custom(userAgent):
            return CrawlerAgent.allCases.first { $0.userAgent == userAgent }
        }
    }
}

/// A named referer origin to spoof (reusing `RefererOrigin`, the same type the
/// browser-tier bypass strategy uses), or an arbitrary custom `Referer` value
/// (e.g. a site that unlocks for a specific referrer). A rule carries at most one.
/// The bundled table only ever names `.google`.
public enum RefererSpoof: Equatable {
    case origin(RefererOrigin)
    case custom(String)
}

/// One site's paywall-unlock config, produced by `scripts/generate_site_rules.js`
/// into the bundled `site_unlock_rules.json`. Every field is optional; a nil field
/// means "this technique isn't used for this site". Group configs are already
/// flattened to one rule per member domain, and `{domain}` placeholders in the
/// regexes are already substituted.
///
/// The JSON also carries `csCode`/`csDompurify` (a small nested cleanup DSL used by
/// a few sites, belonging to the browser tier), header/IP-spoofing and cookie-hold
/// fields with no reader, and JSON-LD reconstruction fields with no reader — none of
/// those are decoded here.
public struct SiteUnlockRule: Decodable, Equatable {
    public let domain: String
    /// Keep cookies (the default is to blank the `Cookie:` request header).
    public let allowCookies: Bool?
    /// Regex sources whose matching script/XHR requests should be blocked (the
    /// metering/paywall vendor scripts). Delimiter-free source strings.
    public let blockRegex: [String]?
    /// Inline-script block pattern (paywall logic inlined into the page).
    public let blockJsInline: String?
    /// The User-Agent this rule spoofs, parsed once from the JSON's `useragent`
    /// (a named crawler) / `useragentCustom` (an arbitrary string) pair.
    public let userAgentSpoof: UserAgentSpoof?
    /// The Referer this rule spoofs, parsed once from the JSON's `referer` (a named
    /// origin) / `refererCustom` (an arbitrary string) pair.
    public let refererSpoof: RefererSpoof?
    /// Delete all stored cookies for the site after load.
    public let removeCookies: Bool?
    /// Delete only these named cookies (the meter counters).
    public let removeCookiesSelectDrop: [String]?
    /// Clear localStorage/sessionStorage (client-side meter store).
    public let clearLocalStorage: Bool?

    private enum CodingKeys: String, CodingKey {
        case domain, allowCookies, blockRegex, blockJsInline
        case useragent, useragentCustom, referer, refererCustom
        case removeCookies, removeCookiesSelectDrop, clearLocalStorage
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        domain = try container.decode(String.self, forKey: .domain)
        allowCookies = try container.decodeIfPresent(Bool.self, forKey: .allowCookies)
        blockRegex = try container.decodeIfPresent([String].self, forKey: .blockRegex)
        blockJsInline = try container.decodeIfPresent(String.self, forKey: .blockJsInline)
        removeCookies = try container.decodeIfPresent(Bool.self, forKey: .removeCookies)
        removeCookiesSelectDrop = try container.decodeIfPresent([String].self, forKey: .removeCookiesSelectDrop)
        clearLocalStorage = try container.decodeIfPresent(Bool.self, forKey: .clearLocalStorage)

        if let named = try container.decodeIfPresent(String.self, forKey: .useragent),
           let crawler = Self.crawler(named: named) {
            userAgentSpoof = .crawler(crawler)
        } else if let custom = try container.decodeIfPresent(String.self, forKey: .useragentCustom) {
            userAgentSpoof = .custom(custom)
        } else {
            userAgentSpoof = nil
        }

        if let named = try container.decodeIfPresent(String.self, forKey: .referer),
           let origin = RefererOrigin(rawValue: named) {
            refererSpoof = .origin(origin)
        } else if let custom = try container.decodeIfPresent(String.self, forKey: .refererCustom) {
            refererSpoof = .custom(custom)
        } else {
            refererSpoof = nil
        }
    }

    /// The crawler identity a rule's `useragent` string names, or nil for an
    /// unrecognized name (dropped, same as if the field were absent).
    private static func crawler(named: String) -> CrawlerAgent? {
        switch named {
        case "googlebot": return .googlebotDesktop
        case "bingbot": return .bingbot
        case "facebookbot": return .facebookbot
        default: return nil
        }
    }
}

/// A global paywall-vendor script blocker: its script/XHR requests are
/// blocked on all sites except `excludedDomains`.
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
        HostSuffixLookup.value(for: url, in: byDomain)
    }

    /// The global vendor-script block patterns (applied to every site except each
    /// entry's `excludedDomains`).
    public static var generalBlockers: [VendorScriptBlocker] { file.generalBlockers }

    /// True when the host is on the known-unfixable denylist, so we shouldn't waste a
    /// bypass attempt on it.
    public static func isNoFix(_ url: URL) -> Bool {
        HostSuffixLookup.contains(url, in: noFixSet)
    }

    /// Total loaded rule count (diagnostics/tests).
    public static var ruleCount: Int { file.rules.count }
}
