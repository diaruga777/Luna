//
//  PaywallDetector.swift
//  Luna
//

import LunaModels
import Foundation
import SwiftSoup

/// Decides whether a page/extracted article is a subscription wall (a metered
/// teaser / "subscribe to continue" stub) rather than the real article — the
/// single source of truth shared by every surface that makes this call (the
/// resolver, `ArticleContent.hasReadableBody`, the archive reader). Content-based
/// (NOT a host allowlist): a reader logged in via their browser gets the full
/// article and is correctly NOT flagged, while a server-side fetch of the same
/// site hits the wall and IS flagged. A JS mirror lives in the Safari extension's
/// `content.js` — keep the marker lists in sync.
public enum PaywallDetector {

    /// "Gate" phrases that only appear when an article body has been CUT OFF behind
    /// a wall — so they signal a paywall at ANY body length (a stub padded out with
    /// subscription-plan copy can still run long). High-precision: each implies the
    /// reader was stopped, not merely that subscribing was mentioned.
    public static let gateMarkers = [
        "to continue reading", "continue reading this article", "continue reading with",
        "login or signup to continue", "log in or sign up to continue",
        "sign in to continue reading", "log in to continue reading",
        "subscribe to continue", "subscribe to read", "register to continue",
        "sign up to continue reading", "subscribe now for unlimited",
        "subscribe for unlimited access", "this article is for subscribers",
        "this story is for subscribers", "this content is for subscribers",
        "available to subscribers", "subscribers only", "subscriber exclusive",
        "to read the full article", "to read the full story", "for full access",
        "already a subscriber? log in", "already a subscriber? sign in",
        "unlock this article", "this article is reserved for subscribers",
    ]

    /// Weaker subscription-marketing phrases that can also appear in the chrome of a
    /// FREE article, so they flag a wall only when the body is SHORT (a stub).
    static let weakMarkers = [
        "try unlimited access", "unlimited digital access", "complete digital access",
        "digital access to quality", "cancel anytime", "subscriber agreement",
        "personal, non-commercial use", "sign in to read", "become a subscriber",
        "start your free trial", "supporter subscription", "subscribe now",
        "create a free account", "support local journalism", "your subscription",
    ]

    /// Bodies shorter than this are eligible to be judged a paywall stub by a weak
    /// marker (a long body with only weak markers is treated as a real article).
    public static let shortBodyThreshold = 2500

    /// Whether the extracted article — optionally with its source HTML — reads as a
    /// paywall wall. `html` (when available) adds the publisher-declared schema.org
    /// signal, but only for short/teaser-shaped bodies: some publishers mark subscriber
    /// pieces with `isAccessibleForFree:false` while still serving the complete article
    /// body in the initial HTML.
    ///
    /// It also adds the STRUCTURAL signal — a subscribe gate that cut the body off
    /// (`TruncationGateDetector`) — and that one applies at ANY body length, because it
    /// is the only wall shape a length test cannot see: a generous-preview publisher
    /// serves thousands of readable characters and then stops mid-article.
    public static func looksPaywalled(content: ArticleContent, html: String? = nil) -> Bool {
        let textPaywalled = textLooksPaywalled(content.wholeText, bodyLength: content.bodyTextLength)
        if textPaywalled { return true }
        guard let html else { return false }
        if htmlDeclaresBodyWithheld(html) { return true }
        if htmlDeclaresLocked(html), content.bodyTextLength < shortBodyThreshold {
            return true
        }
        return htmlShowsTruncationGate(html)
    }

    /// Text-only check (for callers without the source HTML): a gate marker at any
    /// length, or a weak marker in a short body.
    public static func textLooksPaywalled(_ text: String, bodyLength: Int) -> Bool {
        let lowered = text.lowercased()
        if gateMarkers.contains(where: { lowered.contains($0) }) { return true }
        guard bodyLength < shortBodyThreshold else { return false }
        return weakMarkers.contains(where: { lowered.contains($0) })
    }

    /// The publisher-declared paywall signal: schema.org `isAccessibleForFree:false`
    /// in JSON-LD (a precise key+value, so unaffected by stray words elsewhere on the
    /// page), or an `article:content_tier` meta whose value is locked/metered/premium
    /// — matched only when the value sits IN the meta (not a whole-document scan,
    /// which false-flags free pages that merely contain "premium"). Whitespace is
    /// collapsed so attribute spacing/quoting doesn't matter.
    public static func htmlDeclaresLocked(_ html: String) -> Bool {
        let compact = html.lowercased().filter { !$0.isWhitespace }
        if compact.contains("\"isaccessibleforfree\":false")
            || compact.contains("\"isaccessibleforfree\":\"false\"") {
            return true
        }
        return ["locked", "metered", "premium"].contains { value in
            compact.contains("content_tier\"content=\"\(value)")
                || compact.contains("content-tier\"content=\"\(value)")
                || compact.contains("content=\"\(value)\"property=\"article:content_tier")
                || compact.contains("content=\"\(value)\"name=\"article:content_tier")
        }
    }

    /// A stronger publisher state than schema.org's generic "this is premium"
    /// label: the page's own article component explicitly says access is locked AND
    /// that the full body was not sent. This is the shape The Information serves to
    /// signed-out readers. Its only `<article>` is a headline/lock card, while several
    /// thousand characters of navigation and subscription copy elsewhere in `<body>`
    /// can make the extractor's last-resort layer look long enough to read.
    ///
    /// Unlike `htmlDeclaresLocked`, this signal applies at any extracted length. A
    /// long body cannot disprove an explicit `fullText: null`; that length came from
    /// page furniture, not article prose. Scope the JSON read to the publisher's
    /// `Article` React component so an unrelated locked card in a recommendation rail
    /// cannot reject a complete article.
    public static func htmlDeclaresBodyWithheld(_ html: String) -> Bool {
        let compact = html.lowercased().filter { !$0.isWhitespace }
        guard compact.contains("data-component-name=\"article\""),
              compact.contains("\"access\":\"locked\""),
              compact.contains("\"fulltext\":null"),
              let document = try? SwiftSoup.parse(html),
              let scripts = try? document.select(
                "script[type=application/json][data-component-name=Article]")
        else { return false }

        for script in scripts {
            guard let data = script.data().data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let article = root["article"] as? [String: Any],
                  (article["access"] as? String)?.lowercased() == "locked",
                  article.keys.contains("fullText"), article["fullText"] is NSNull
            else { continue }
            return true
        }
        return false
    }

    /// The structural paywall signal: a subscribe gate standing where the rest of the
    /// article should be (`TruncationGateDetector`). Unlike every other signal this one
    /// survives a LONG body, which is the whole point — see that type for why a
    /// generous free preview is invisible to the length and metadata checks.
    static func htmlShowsTruncationGate(_ html: String) -> Bool {
        TruncationGateDetector.showsTruncationGate(in: html)
    }
}
