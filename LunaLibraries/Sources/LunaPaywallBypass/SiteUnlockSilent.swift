//
//  SiteUnlockSilent.swift
//  LunaPaywallBypass
//

import LunaFetch
import LunaURLClassification
import Foundation

/// The silent (URLSession) leg of the site paywall-unlock engine: applies a rule's
/// REQUEST-level technique — a crawler/custom User-Agent, a spoofed Referer, an
/// `X-Forwarded-For`, and cookie handling — then leaves extraction to the caller.
///
/// Request-only techniques are the ones a background fetch can honor. Script blocking
/// (`blockRegex`) and DOM cleanup (`csDompurify`, `cs_code`) need a rendered page and
/// belong to the WKWebView browser tier, so this returns nil for rules that carry only
/// those. The dispatch reuses the existing `HTMLFetching` primitives (each already
/// pairs a UA/referer transform with the right cookie mode), so no new fetch surface
/// is needed.
public enum SiteUnlockSilent {

    /// The request transform a rule's silent fetch would apply — computed purely (no
    /// I/O) so the mapping is unit-testable.
    public enum FetchKind: Equatable {
        /// Crawler or custom User-Agent, over a cookieless session (a real crawler
        /// presents no cookies), with an optional `X-Forwarded-For`.
        case userAgent(String, xForwardedFor: String?)
        /// A spoofed `Referer`, over the normal (cookie-bearing) session.
        case referer(String)
        /// A fresh cookieless visit (resets a client-side metered counter).
        case freshSession
        /// No request-level technique — the browser tier must handle this site.
        case none
    }

    static let googleReferer = RefererOrigin.google.url

    /// The request transform for `rule` (request-level techniques only).
    public static func fetchKind(for rule: SiteUnlockRule) -> FetchKind {
        if let userAgentSpoof = rule.userAgentSpoof {
            switch userAgentSpoof {
            case .crawler(let agent):
                return .userAgent(agent.userAgent, xForwardedFor: agent.xForwardedFor)
            case .custom(let custom):
                return .userAgent(custom, xForwardedFor: nil)
            }
        }
        if let refererSpoof = rule.refererSpoof {
            switch refererSpoof {
            case .origin(let origin):
                return .referer(origin.url)
            case .custom(let custom):
                return .referer(custom)
            }
        }
        // Only cookies to reset and no UA/referer lever → a fresh cookieless visit.
        if rule.allowCookies != true,
           rule.removeCookies == true || rule.removeCookiesSelectDrop != nil || rule.clearLocalStorage == true {
            return .freshSession
        }
        return .none
    }

    /// Fetches `url` applying `rule`'s silent request technique, or nil when the rule
    /// has no request-level technique (the browser tier owns it). Throws on fetch
    /// failure like the underlying `HTMLFetching` calls.
    public static func fetch(
        url: URL, rule: SiteUnlockRule, fetcher: HTMLFetching
    ) async throws -> String? {
        switch fetchKind(for: rule) {
        case let .userAgent(agent, xff):
            return try await fetcher.fetchHTML(from: url, userAgent: agent, xForwardedFor: xff)
        case let .referer(referer):
            return try await fetcher.fetchHTML(from: url, referer: referer)
        case .freshSession:
            return try await fetcher.fetchHTMLWithoutCookies(from: url)
        case .none:
            return nil
        }
    }
}
