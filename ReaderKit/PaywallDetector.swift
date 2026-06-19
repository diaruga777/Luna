//
//  PaywallDetector.swift
//  ReaderKit
//

import Foundation

/// Decides whether a page/extracted article is a subscription wall (a metered
/// teaser / "subscribe to continue" stub) rather than the real article — the
/// single source of truth shared by every surface that makes this call (the
/// resolver, `ArticleContent.hasReadableBody`, the archive reader). Content-based
/// (NOT a host allowlist): a reader logged in via their browser gets the full
/// article and is correctly NOT flagged, while a server-side fetch of the same
/// site hits the wall and IS flagged. A JS mirror lives in the Safari extension's
/// `content.js` — keep the marker lists in sync.
enum PaywallDetector {

    /// "Gate" phrases that only appear when an article body has been CUT OFF behind
    /// a wall — so they signal a paywall at ANY body length (a stub padded out with
    /// subscription-plan copy can still run long). High-precision: each implies the
    /// reader was stopped, not merely that subscribing was mentioned.
    static let gateMarkers = [
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
    static let shortBodyThreshold = 2500

    /// Whether the extracted article — optionally with its source HTML — reads as a
    /// paywall wall. `html` (when available) adds the publisher-declared schema.org
    /// signal, which catches walls whose CTA text the extractor stripped out.
    static func looksPaywalled(content: ArticleContent, html: String? = nil) -> Bool {
        if let html, htmlDeclaresLocked(html) { return true }
        return textLooksPaywalled(content.wholeText, bodyLength: content.bodyTextLength)
    }

    /// Text-only check (for callers without the source HTML): a gate marker at any
    /// length, or a weak marker in a short body.
    static func textLooksPaywalled(_ text: String, bodyLength: Int) -> Bool {
        let lowered = text.lowercased()
        if gateMarkers.contains(where: { lowered.contains($0) }) { return true }
        guard bodyLength < shortBodyThreshold else { return false }
        return weakMarkers.contains(where: { lowered.contains($0) })
    }

    /// The publisher-declared paywall signal: schema.org `isAccessibleForFree:false`
    /// in JSON-LD, or an `article:content_tier` / `content-tier` meta of
    /// locked/metered/premium. Whitespace is collapsed so attribute spacing/quoting
    /// doesn't matter.
    static func htmlDeclaresLocked(_ html: String) -> Bool {
        let compact = html.lowercased().filter { !$0.isWhitespace }
        if compact.contains("\"isaccessibleforfree\":false")
            || compact.contains("\"isaccessibleforfree\":\"false\"") {
            return true
        }
        if compact.contains("content_tier") || compact.contains("content-tier") {
            if compact.contains("locked") || compact.contains("metered")
                || compact.contains("premium") || compact.contains("subscriber") {
                return true
            }
        }
        return false
    }
}
