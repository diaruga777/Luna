//
//  ComparisonMatching.swift
//  LunaPriceCompare
//

import Foundation
import LunaModels
import LunaPriceMetadata

/// How strongly a candidate seller page was matched to the source product.
/// Ordered, because the merge rule lets a better-verified result for the same
/// retailer supplant a weaker one.
public enum SellerMatchConfidence: Int, Comparable, Codable, Sendable {
    /// Fuzzy product-name overlap plus a compatible brand — only accepted when
    /// the source itself declared no cross-host identifier at all.
    case name = 0
    /// The page does not DECLARE the GTIN in structured data, but it was reached
    /// by searching this retailer's own site for the GTIN's digits, its markup
    /// contains those digits, and its name matches. See `ComparisonMatching`'s
    /// third tier for why that is identifier evidence rather than a guess.
    case gtinInPage = 1
    /// Manufacturer part number equality with a compatible brand.
    case mpn = 2
    /// GTIN equality — the same physical product, by definition.
    case gtin = 3

    public static func < (lhs: SellerMatchConfidence, rhs: SellerMatchConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// What is known about HOW a candidate page was reached and what its markup
/// says, beyond the structured fields a parser could pull out of it.
///
/// This exists because the strongest evidence a real retailer offers is often
/// not structured at all: it answered a search for a specific GTIN with this
/// page, and the digits are on it.
public struct CandidatePageEvidence: Sendable {
    /// Whether the page was reached by searching the retailer's OWN site for
    /// the source product's GTIN digits (as opposed to its name).
    public let reachedByGTINSearch: Bool
    /// The candidate page's raw markup, when the caller still has it.
    public let html: String?
    /// The candidate page's URL — some retailers put the identifier there
    /// (Amazon's book ASINs ARE the ISBN-10).
    public let url: URL?

    public init(reachedByGTINSearch: Bool = false, html: String? = nil, url: URL? = nil) {
        self.reachedByGTINSearch = reachedByGTINSearch
        self.html = html
        self.url = url
    }

    /// No evidence beyond the parse — the default, and what a web-search hit
    /// starts with.
    public static let none = CandidatePageEvidence()
}

/// Decides whether a page found on another retailer is THE SAME PRODUCT as the
/// one being compared — the single decision the whole feature's credibility
/// rests on. Showing "$9.50 at Amazon" for a different product is worse than
/// showing nothing, so the tiers are strict and the fallback is narrow.
///
/// Tiers, strongest first:
/// 1. Normalized GTIN equality (zero-padded to 14, so GTIN-8/12/13/14 of the
///    same number agree) → accept.
/// 2. MPN equality with a compatible brand → accept. An MPN is
///    manufacturer-scoped, so two retailers' identical MPNs under conflicting
///    brands are not the same part.
/// 3. The name matches AND the page states the source's GTIN without declaring
///    it structurally → accept as `.gtinInPage`. This tier exists because tier 1
///    is unreachable on most real retail pages: Amazon publishes no JSON-LD
///    `Product` at all, so a page found by searching amazon.com for the exact
///    GTIN, whose markup and URL both carry that GTIN, and whose title matches,
///    was being REFUSED for having no structured identifier. Reaching the page
///    by a GTIN search is what makes the containment meaningful — see
///    `pageStatesSourceGTIN` — and it is cheap string evidence rather than a
///    guess, so even the constrained profile accepts it.
/// 4. Jaccard name similarity ≥ `ProductIdentityMatching.nameThreshold` with a
///    compatible brand → accept, but ONLY when name matching is enabled for
///    this profile AND the source declared no GTIN or MPN. If the source has a
///    strong id and the candidate does not present the same one, a name
///    coincidence is not evidence — it is the accessory, the older model, or
///    the two-pack. (The audiobook edition of a title is the worked example: it
///    matches the paperback by name and does NOT carry the paperback's ISBN, so
///    tier 3 refuses it and tier 4 never runs.)
///
/// The primitives underneath live in `ProductIdentityMatching` (LunaModels), and
/// `ComparisonMatchingParityTests` pins their behaviour to
/// `ProductMatcher`/`SnapshotMatcher`'s long-standing copies.
public enum ComparisonMatching {

    /// The confidence at which `candidate` is the same product as `source`, or
    /// nil when it is not a match at any tier.
    public static func verify(
        source: ProductIdentifiers,
        sourceName: String,
        candidate: ProductIdentifiers,
        candidateName: String,
        evidence: CandidatePageEvidence = .none,
        allowsNameOnlyMatch: Bool
    ) -> SellerMatchConfidence? {
        if let sourceGTIN = source.normalizedGTIN, let candidateGTIN = candidate.normalizedGTIN {
            return sourceGTIN == candidateGTIN ? .gtin : nil
        }
        if let sourceMPN = source.normalizedMPN, let candidateMPN = candidate.normalizedMPN,
           sourceMPN == candidateMPN,
           ProductIdentityMatching.brandsCompatible(source.brand, candidate.brand) {
            return .mpn
        }
        if namesAgree(sourceName, candidateName, source: source, candidate: candidate) {
            if pageStatesSourceGTIN(source: source, evidence: evidence) { return .gtinInPage }
            if allowsNameOnlyMatch, !source.hasCrossHostIdentifier { return .name }
        }
        return nil
    }

    /// Whether the ONLY thing standing between this candidate and the
    /// `.gtinInPage` tier is the page itself — i.e. everything cheap has been
    /// checked and the answer now depends on markup the caller may not have.
    ///
    /// The fan-out asks this before spending a fetch to go and get that markup,
    /// which is the whole reason it is a separate question.
    public static func requiresPageEvidence(
        source: ProductIdentifiers,
        sourceName: String,
        candidate: ProductIdentifiers,
        candidateName: String
    ) -> Bool {
        guard source.normalizedGTIN != nil, candidate.normalizedGTIN == nil else { return false }
        if let sourceMPN = source.normalizedMPN, let candidateMPN = candidate.normalizedMPN,
           sourceMPN == candidateMPN,
           ProductIdentityMatching.brandsCompatible(source.brand, candidate.brand) {
            return false
        }
        return namesAgree(sourceName, candidateName, source: source, candidate: candidate)
    }

    static func namesAgree(
        _ sourceName: String, _ candidateName: String,
        source: ProductIdentifiers, candidate: ProductIdentifiers
    ) -> Bool {
        ProductIdentityMatching.brandsCompatible(source.brand, candidate.brand)
            && ProductIdentityMatching.nameSimilarity(
                ProductTitleHygiene.cleaned(sourceName),
                ProductTitleHygiene.cleaned(candidateName))
                >= ProductIdentityMatching.nameThreshold
    }

    /// Whether the candidate page itself states the source's GTIN.
    ///
    /// Both halves are required and neither is sufficient. The SEARCH half —
    /// that this page came back from asking the retailer's own site for these
    /// exact digits — is what makes the containment meaningful rather than
    /// coincidental; the CONTAINMENT half is what stops a search engine's
    /// "related items" rail from being taken as an answer.
    ///
    /// Every written form of the number is tried (`GTINForms.variants`), because
    /// a retailer that stores an EAN-13 may print the UPC-12, and a bookshop
    /// that was asked for an ISBN-13 routinely prints the ISBN-10 — including,
    /// notably, in Amazon's `/dp/<isbn10>` URL, which is why the URL is checked
    /// alongside the markup.
    public static func pageStatesSourceGTIN(
        source: ProductIdentifiers, evidence: CandidatePageEvidence
    ) -> Bool {
        guard evidence.reachedByGTINSearch, let gtin = source.gtin else { return false }
        let variants = GTINForms.variants(of: gtin)
        guard !variants.isEmpty else { return false }
        if let url = evidence.url {
            let text = url.absoluteString
            if variants.contains(where: { text.contains($0) }) { return true }
        }
        guard let html = evidence.html else { return false }
        if variants.contains(where: { html.contains($0) }) { return true }
        // A page that prints the number with separators — `978-0-7352-1129-2`,
        // `0 735211 299`. Only the long forms are worth this second pass: an
        // eight-digit string interrupted by hyphens is not evidence of anything.
        return variants
            .filter { $0.count >= 12 }
            .contains { html.range(of: separatedPattern(for: $0), options: .regularExpression) != nil }
    }

    /// `9780735211292` → `9[-\s]?7[-\s]?8…`, so a hyphenated printing matches.
    static func separatedPattern(for digits: String) -> String {
        digits.map { String($0) }.joined(separator: "[-\\s]?")
    }
}

/// Recognizes the "you are a robot" answer a retailer serves instead of a page.
///
/// Bot walls are an EXPECTED outcome for some tier-1 sellers, not an error —
/// they are precisely why the candidate list is over-provisioned relative to the
/// result target. What matters is recognizing one fast, so the run spends its
/// budget elsewhere and never asks the same host twice.
public enum BotWallDetection {

    /// HTTP statuses that mean "refused", as distinct from "not found" (404 is
    /// an ordinary miss — the search simply had no such product).
    public static let blockedStatusCodes: Set<Int> = [401, 403, 405, 429, 503]

    /// Needles that appear in an interstitial challenge page served with a 200.
    static let challengeNeedles = [
        "captcha",
        "are you a human",
        "are you a robot",
        "unusual traffic",
        "verify you are a human",
        "access denied",
        "enable javascript and cookies",
        "request unsuccessful. incapsula",
        "pardon our interruption",
        "checking your browser before",
        "ddos protection by",
    ]

    /// A challenge page is short and repetitive; a real product page is not.
    /// Above this length a stray "captcha" word (a product actually named
    /// "CAPTCHA", a privacy footer) should not condemn the page.
    static let maximumChallengeLength = 60_000

    public static func isBotWall(statusCode: Int, html: String) -> Bool {
        if blockedStatusCodes.contains(statusCode) { return true }
        guard html.count <= maximumChallengeLength else { return false }
        let lowered = html.lowercased()
        return challengeNeedles.contains { lowered.contains($0) }
    }
}
