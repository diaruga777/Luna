//
//  PluginCrawlerIdentity.swift
//  LunaPluginKit
//

import Foundation

/// The named fetcher identities `luna.fetch`'s `userAgent` accepts.
///
/// The strings are copies of `CrawlerAgent`'s (LunaPaywallBypass), because
/// `LunaPluginKit` is linked by the Safari appex and cannot afford the bypass
/// tier's dependencies. `PluginCrawlerIdentityParityTests` compares the two
/// tables, so the copy cannot drift from the original.
public enum PluginCrawlerIdentity: String, CaseIterable, Sendable {
    case safari
    case googlebot
    case googlebotMobile = "googlebot-mobile"
    case bingbot
    case facebookbot

    /// The literal `User-Agent` to send.
    public var userAgent: String {
        switch self {
        case .safari:
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
        case .googlebot:
            return "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
        case .googlebotMobile:
            return "Mozilla/5.0 (Linux; Android 6.0.1; Nexus 5X Build/MMB29P) "
                + "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/80.0.3987.92 Mobile Safari/537.36 "
                + "(compatible; Googlebot/2.1; +http://www.google.com/bot.html)"
        case .bingbot:
            return "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)"
        case .facebookbot:
            return "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)"
        }
    }

    /// A real crawler IP for `X-Forwarded-For`. Only the Google identities send
    /// one: the header's only use is a reverse-proxy allowlist keyed to Google's
    /// ranges, and claiming a Google IP under another token is a contradiction a
    /// bot-management edge can match on.
    public var xForwardedFor: String? {
        switch self {
        case .googlebot, .googlebotMobile: return "66.249.66.1"
        case .safari, .bingbot, .facebookbot: return nil
        }
    }

    /// The identity for a manifest's spelling, or nil when the plugin wrote its
    /// own literal User-Agent instead.
    public static func named(_ name: String) -> PluginCrawlerIdentity? {
        PluginCrawlerIdentity(rawValue: name)
    }
}
