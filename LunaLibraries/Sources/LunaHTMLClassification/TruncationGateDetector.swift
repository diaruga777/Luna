//
//  TruncationGateDetector.swift
//  LunaHTMLClassification
//

import Foundation
import SwiftSoup

/// Detects the one paywall shape a body-LENGTH check can never see: the publisher
/// ships a long, genuinely readable free preview, cuts the prose off **server-side**,
/// and appends a subscribe gate where the rest of the article should be.
///
/// Every other paywall signal Luna has keys off the body being *thin*
/// (`PaywallDetector.shortBodyThreshold`, `ArticleContent.readableBodyThreshold`) or
/// off the publisher declaring the lock in metadata (`HTMLClassification.declaresPaywall`).
/// A generous-preview site trips neither: `theparisreview.org` serves ~12 000 characters
/// of a ~50 000-character interview with no `isAccessibleForFree`, no
/// `article:content_tier`, and no JSON-LD `articleBody` — so the truncated preview read
/// as a complete article, no bypass was ever attempted, and the item was saved ending
/// mid-interview.
///
/// The gate CTA can't be found by scanning the extracted text either: `ArticleExtractor`
/// strips `[class*=paywall]` nodes, so the "Already a subscriber? Sign in" wording is
/// gone by the time `PaywallDetector` sees the body. This detector therefore works on
/// the SOURCE HTML and looks for the *structure* — a wall container that terminates the
/// prose — rather than for words anywhere on the page (which would false-flag every
/// free article on a subscription publisher, whose nav carries the same sign-in copy).
public enum TruncationGateDetector {

    /// Class/id tokens publishers give the wall container itself. Matched as a
    /// substring of the normalized attribute, so `paywall-base` / `article-paywall` /
    /// `regwall__container` all hit.
    static let containerTokens = [
        "paywall", "pay-wall", "regwall", "reg-wall", "registration-wall",
        "subscribe-wall", "subscription-wall", "subscriber-wall",
        "article-gate", "content-gate", "premium-gate", "meter-gate", "piano-gate",
    ]

    /// Prose that must PRECEDE the gate for it to read as a truncation rather than a
    /// whole-page interstitial. Matches `ArticleContent.readableBodyThreshold`: below it
    /// the page is a thin stub the existing length-based signals already catch.
    static let minimumPrecedingProse = 1200

    /// Within the truncated container, the gate may be followed by at most this fraction
    /// of the prose that precedes it. A wall that TRUNCATES is the LAST thing in the
    /// article container; a wall container sitting mid-body on an already-UNLOCKED
    /// capture still has the rest of the story after it, and must not read as a
    /// truncation.
    static let maximumFollowingProseRatio = 0.2

    /// A container holding at least this much prose is an article WRAPPER that merely
    /// carries a wall class (WSJ renders the unlocked body inside `.paywall …
    /// PaywalledContent`), not gate furniture. Mirrors the same exemption in
    /// `ArticleExtractor.isArticleHeavyPaywallWrapper`, which keeps such a wrapper's
    /// text instead of stripping it.
    static let maximumGateProse = 800

    /// A paragraph shorter than this is furniture (a caption, a byline, a footer line),
    /// not prose worth measuring.
    private static let minimumParagraphLength = 40

    /// Whether `html` shows a subscribe gate that CUT OFF the article body: a wall
    /// container that carries stop-the-reader CTA wording, holds no article of its own,
    /// and ENDS the container it sits in — substantial prose before it, essentially none
    /// after it.
    ///
    /// The before/after comparison is scoped to the smallest ancestor that actually holds
    /// the preview (for `theparisreview.org`, the `.article-body-wrap` around
    /// `<main class="article-body">` and the `.paywall` sibling that replaces the rest of
    /// the interview). Scoping is what makes the signal usable: measured across the whole
    /// document, a publisher's "read next" rail — the Wayback capture of this very page
    /// carries 11 000 characters of a DIFFERENT interview below the wall — swamps the
    /// comparison.
    ///
    /// Deliberately narrow — a false positive costs a pointless bypass attempt, and on a
    /// page with no archive coverage it downgrades a readable save to "needs archive".
    /// Prose is measured over `<p>` elements only, so a publisher who builds paragraphs
    /// out of `<div>`s simply isn't detected here (the length- and metadata-based signals
    /// still apply).
    public static func showsTruncationGate(in html: String) -> Bool {
        guard let body = try? SwiftSoup.parse(html).body(),
              let elements = try? body.getAllElements().array()
        else { return false }

        // Document-order position of every element, so "before/after the gate" is one
        // lookup instead of a scan per paragraph.
        var position: [ObjectIdentifier: Int] = [:]
        position.reserveCapacity(elements.count)
        for (index, element) in elements.enumerated() {
            position[ObjectIdentifier(element)] = index
        }
        let paragraphs: [Paragraph] = elements
            .filter { $0.tagName().lowercased() == "p" }
            .compactMap { paragraph in
                guard let index = position[ObjectIdentifier(paragraph)] else { return nil }
                let length = ((try? paragraph.text()) ?? "").count
                guard length >= minimumParagraphLength else { return nil }
                return Paragraph(element: paragraph, index: index, length: length)
            }

        for (gateIndex, gate) in elements.enumerated() where isGateContainer(gate) {
            guard carriesGateWording(gate), proseLength(in: gate) < maximumGateProse else {
                continue
            }
            if truncatesItsContainer(gate: gate, gateIndex: gateIndex, paragraphs: paragraphs) {
                return true
            }
        }
        return false
    }

    /// A `<p>` worth measuring, with its document-order position.
    private struct Paragraph {
        let element: Element
        let index: Int
        let length: Int
    }

    /// Whether `gate` ends the prose of the container it truncates: walking outward from
    /// the gate, the FIRST ancestor holding enough preview prose decides (a wider ancestor
    /// would only pull in the page's other rails).
    private static func truncatesItsContainer(
        gate: Element, gateIndex: Int, paragraphs: [Paragraph]
    ) -> Bool {
        var scope = gate.parent()
        while let container = scope {
            var before = 0
            var after = 0
            for paragraph in paragraphs
            where isInside(paragraph.element, of: container) && !isInside(paragraph.element, of: gate) {
                if paragraph.index < gateIndex { before += paragraph.length }
                else { after += paragraph.length }
            }
            if before >= minimumPrecedingProse {
                return Double(after) <= maximumFollowingProseRatio * Double(before)
            }
            scope = container.parent()
        }
        return false
    }

    /// Whether the element's own `class`/`id` names it a wall container.
    private static func isGateContainer(_ element: Element) -> Bool {
        let attributes = [(try? element.attr("class")) ?? "", (try? element.attr("id")) ?? ""]
            .joined(separator: " ")
            .lowercased()
        guard !attributes.isEmpty else { return false }
        return containerTokens.contains { attributes.contains($0) }
    }

    /// Whether the container's text says the reader was STOPPED — a high-precision
    /// `PaywallDetector.gateMarkers` phrase. A container with only marketing copy
    /// ("subscribe now") is an ad rail, not a gate.
    private static func carriesGateWording(_ element: Element) -> Bool {
        let text = ((try? element.text()) ?? "").lowercased()
        guard !text.isEmpty else { return false }
        return PaywallDetector.gateMarkers.contains { text.contains($0) }
    }

    /// Prose length inside `element` — its own paragraphs, the article-wrapper test.
    private static func proseLength(in element: Element) -> Int {
        ((try? element.select("p").array()) ?? []).reduce(0) { total, paragraph in
            let length = ((try? paragraph.text()) ?? "").count
            return total + (length >= minimumParagraphLength ? length : 0)
        }
    }

    private static func isInside(_ element: Element, of ancestor: Element) -> Bool {
        var parent = element.parent()
        while let current = parent {
            if current === ancestor { return true }
            parent = current.parent()
        }
        return false
    }
}
