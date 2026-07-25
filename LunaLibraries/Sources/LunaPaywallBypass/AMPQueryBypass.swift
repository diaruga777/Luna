//
//  AMPQueryBypass.swift
//  LunaPaywallBypass
//

import Foundation
import SwiftSoup

/// Paywall bypass via the publisher's own **AMP rendering, addressed by query**
/// (`<article>?amp`) rather than by a `rel=amphtml` link.
///
/// News Corp Australia (`theaustralian.com.au`, `heraldsun.com.au`,
/// `dailytelegraph.com.au`, …) is the family this exists for, and it is a different
/// shape from every other bypass in the plan:
///
/// - A plain GET of a premium article REDIRECTS to `…/subscribe/news/1/?dest=<article>`,
///   so there is no article HTML to work with at all — no teaser to un-clamp, no
///   `rel=amphtml` link to discover (`.amp` needs the article page to advertise one),
///   and nothing for a JSON-LD reconstruction to read.
/// - The same URL with `?amp` is NOT redirected, and the AMP document it returns
///   carries the COMPLETE body server-rendered, in `<section subscriptions-section=
///   "content">` blocks that only `amp-subscriptions-*.js` hides — client-side, after
///   load. A background URLSession fetch never runs that script, so the plain bytes
///   are the whole article. (Verified live against the reported article: the direct
///   read lands on the subscription pitch, `?amp` returns ~7k characters of body.)
///
/// So it is a *silent* strategy — the cheapest possible unlock for these hosts, no
/// browser, no archive, no CAPTCHA. Host-gated on purpose: `?amp` is meaningless on a
/// site that doesn't route AMP by query, and a strategy that fires everywhere would
/// spend a request per save to learn that. The browser tier's own
/// `site_cleanup_scripts.json` entry for the same family (the `/subscribe/` hop plus
/// the AMP unhide) stays as the fallback when the silent fetch can't get through.
public enum AMPQueryBypass {

    /// Registrable domains whose articles serve a full-body AMP document at
    /// `?amp` — the News Corp Australia mastheads, matching the group the upstream
    /// rule table blocks `amp-subscriptions-*.js` for (`site_unlock_rules.json`) and
    /// the group the browser-tier cleanup script already handles.
    public static let hosts: Set<String> = [
        "theaustralian.com.au",
        "adelaidenow.com.au",
        "cairnspost.com.au",
        "codesports.com.au",
        "couriermail.com.au",
        "dailytelegraph.com.au",
        "geelongadvertiser.com.au",
        "goldcoastbulletin.com.au",
        "heraldsun.com.au",
        "ntnews.com.au",
        "thechronicle.com.au",
        "themercury.com.au",
        "townsvillebulletin.com.au",
        "weeklytimesnow.com.au",
    ]

    /// Whether `url`'s host is one of the AMP-by-query mastheads (exact host or any
    /// subdomain, so `www.theaustralian.com.au` matches). A trailing dot is tolerated.
    public static func isAMPQueryHost(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: ".")), !host.isEmpty
        else { return false }
        if hosts.contains(host) { return true }
        return hosts.contains { host.hasSuffix("." + $0) }
    }

    /// The `?amp` variant of an article URL — the flag is appended as a valueless
    /// query item, so an article that already carries query parameters keeps them
    /// (`…/news-story/<id>?utm_source=x` → `…?utm_source=x&amp`). Nil when the host
    /// isn't an AMP-by-query masthead or the URL already asks for AMP (so the
    /// strategy can never re-fetch the page it just fetched).
    public static func ampQueryURL(for url: URL) -> URL? {
        guard isAMPQueryHost(url), !asksForAMP(url) else { return nil }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        // A bare flag, not `amp=1`: that is the form the sites themselves emit and the
        // form their edge matches on.
        components.query = [components.query, "amp"].compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "&")
        components.fragment = nil
        return components.url
    }

    /// The same AMP document with its subscriber GATE removed: every
    /// `[subscriptions-section="content-not-granted"]` node (the "Already a
    /// subscriber? Log in / Get the full story" panel) is dropped, and the
    /// `subscriptions-section` attribute is stripped from the content blocks.
    ///
    /// This is not cosmetic. AMP ships both the article and the pitch in the same
    /// document and lets `amp-subscriptions` choose between them at runtime, so a
    /// silent fetch sees BOTH — and the pitch carries gate wording
    /// (`PaywallDetector.gateMarkers` matches "already a subscriber? log in" at any
    /// body length), which would make the extractor reject a document that holds the
    /// complete story. Removing the machine-labeled gate is what lets the real
    /// paywall judgment run on the real body. The browser tier does exactly the same
    /// thing in JS (`site_cleanup_scripts.json`, upstream's
    /// `amp_unhide_subscr_section`).
    ///
    /// Pure. Returns `html` unchanged when it can't be parsed or carries no AMP
    /// subscription markup.
    public static func unhidingAMPGate(in html: String) -> String {
        guard html.contains("subscriptions-section"),
              let document = try? SwiftSoup.parse(html)
        else { return html }
        do {
            for gate in try document.select("[subscriptions-section]").array() {
                let role = (try? gate.attr("subscriptions-section"))?.lowercased() ?? ""
                if role == "content" {
                    try gate.removeAttr("subscriptions-section")
                } else {
                    // Everything else is gate furniture: `content-not-granted` (the
                    // pitch), `content-not-granted-preview`, and any future variant.
                    try gate.remove()
                }
            }
            return try document.html()
        } catch {
            return html
        }
    }

    /// Whether `url` already requests the AMP rendering — an `amp` query item (with or
    /// without a value) or an `/amp` path leaf.
    public static func asksForAMP(_ url: URL) -> Bool {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if query.contains(where: { $0.name.lowercased() == "amp" }) { return true }
        return url.path.split(separator: "/").last?.lowercased() == "amp"
    }
}
