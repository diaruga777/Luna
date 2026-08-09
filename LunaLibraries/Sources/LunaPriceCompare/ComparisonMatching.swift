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
    /// A stricter name match (0.75, not 0.6) PLUS the source's own
    /// model-code-like token (`HRFD634BW`) appearing on the candidate page —
    /// accepted even though the source declared a GTIN/MPN the candidate does
    /// not present, because most retail pages that carry no structured
    /// identifier still print the model code verbatim in their own title.
    /// See `ComparisonMatching`'s "relaxed name" tier.
    case nameWithModelCode = 1
    /// The page does not DECLARE the GTIN in structured data, but its markup
    /// (or URL) contains the source GTIN's digits and its name matches. See
    /// `ComparisonMatching`'s GTIN-in-page tier for why that is identifier
    /// evidence rather than a guess.
    case gtinInPage = 2
    /// The page does not declare the source's MPN structurally, but its
    /// markup/URL/title contains the MPN token and its name matches — the MPN
    /// analogue of `.gtinInPage`.
    case mpn = 3
    /// GTIN equality — the same physical product, by definition.
    case gtin = 4

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
///    same number agree) → accept. A DECLARED, DIFFERENT GTIN on the
///    candidate is a refusal, not a fall-through: both sides named the
///    product globally and named different products.
/// 2. MPN equality with a compatible brand → accept. An MPN is
///    manufacturer-scoped, so two retailers' identical MPNs under conflicting
///    brands are not the same part.
/// 3. The name matches (the ordinary 0.6 threshold) AND the page CONTAINS the
///    source's GTIN digits or its own declared MPN → accept as `.gtinInPage`
///    / `.mpn`. This tier exists because tier 1/2 are unreachable on most real
///    retail pages: Amazon publishes no JSON-LD `Product` at all, so a page
///    whose markup and URL both carry the exact GTIN, with a matching title,
///    was being refused for having no STRUCTURED identifier. Originally this
///    only fired when the page had been reached by asking the retailer's own
///    site for the GTIN's digits — but a web-search hit (Layer 2, or a
///    retailer's search buried under a NAME query) lands on the exact same
///    page just as often, and the name match is what makes containment
///    meaningful there too; requiring search provenance on top of it was
///    refusing evidence this tier exists to accept (see `pageStatesSourceGTIN`
///    / `pageContainsSourceMPN`).
/// 4. Jaccard name similarity ≥ `ProductIdentityMatching.nameThreshold` with a
///    compatible brand → accept as `.name`, but ONLY when name matching is
///    enabled for this profile AND the source declared no GTIN or MPN. If the
///    source has a strong id and the candidate does not present the same one,
///    a name coincidence is not evidence — it is the accessory, the older
///    model, or the two-pack. (The audiobook edition of a title is the worked
///    example: it matches the paperback by name and does NOT carry the
///    paperback's ISBN, so tier 3 refuses it and tier 4 never runs.)
/// 5. **Relaxed name, for a candidate with NO structured identifiers at all**
///    (no GTIN, MPN or SKU) when the source declares a GTIN/MPN → accept as
///    `.nameWithModelCode`, but only when name matching is enabled AND name
///    similarity clears a HIGHER bar (0.75) AND, whenever the source's own
///    name or MPN carries a model-code-like token (a mixed letter+digit run
///    of 6+ characters, e.g. `HRFD634BW`), that exact token appears on the
///    candidate page too. A plain retail listing rarely ships ANY machine-
///    readable identifier, but its own title almost always repeats the
///    manufacturer's model code verbatim — which is the discriminator that
///    keeps this from reopening the case/older-model/two-pack trap tier 4
///    exists to avoid.
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
            if pageContainsSourceMPN(source: source, candidate: candidate, evidence: evidence) {
                return .mpn
            }
            if allowsNameOnlyMatch, !source.hasCrossHostIdentifier { return .name }
        }
        if allowsNameOnlyMatch,
           matchesByRelaxedNameWithModelCode(
            source: source, sourceName: sourceName,
            candidate: candidate, candidateName: candidateName, evidence: evidence) {
            return .nameWithModelCode
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
    /// Reaching the page by asking THIS retailer for the GTIN's digits used to
    /// be a third, separately-required condition here. It no longer is: the
    /// caller already requires the NAME to agree before asking this question
    /// (`verify`'s nesting), and that is what stops a "related items" rail
    /// from being taken as an answer — a page that is not the same product
    /// rarely shares both a matching title AND the exact GTIN by coincidence.
    /// Search provenance still matters elsewhere (it is what makes a SECOND
    /// fetch worth its cost in `SellerFanOut.verify`), but it is no longer a
    /// precondition for accepting evidence the caller already has in hand —
    /// see the type-level doc's tier 3 for the measured case this closed
    /// (a name-matching, GTIN-printing Costco/JB-style page found by a NAME
    /// query, not a GTIN one).
    ///
    /// Every written form of the number is tried (`GTINForms.variants`), because
    /// a retailer that stores an EAN-13 may print the UPC-12, and a bookshop
    /// that was asked for an ISBN-13 routinely prints the ISBN-10 — including,
    /// notably, in Amazon's `/dp/<isbn10>` URL, which is why the URL is checked
    /// alongside the markup.
    public static func pageStatesSourceGTIN(
        source: ProductIdentifiers, evidence: CandidatePageEvidence
    ) -> Bool {
        guard let gtin = source.gtin else { return false }
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

    /// The MPN analogue of `pageStatesSourceGTIN`: the source declares an MPN,
    /// the candidate does NOT declare a conflicting one structurally, and the
    /// MPN token turns up in the candidate's URL or markup. This is what lets
    /// an MPN-only source (a Bing Lee-style save with a degraded extraction —
    /// brand + MPN, no GTIN) verify a candidate whose own PDP happens to be
    /// the one with no structured data at all.
    ///
    /// Deliberately checks the URL/markup ONLY, never `candidateName` — the
    /// cleaned name the caller already ran through `namesAgree` before
    /// reaching this tier at all. A product's own MPN is very often literally
    /// a substring of its own display name ("Sony WH-1000XM5 Headphones"
    /// contains "WH-1000XM5"), so checking the name AGAIN here would mostly
    /// just re-confirm namesAgree's own verdict rather than add independent
    /// evidence — exactly the redundancy `ComparisonMatchingTests
    /// .testNameMatchIsRefusedWhenTheSourceHasACrossHostIdentifier` pins
    /// against (two IDENTICAL titles, one side with no declared MPN at all,
    /// must still refuse). The URL/markup are independent of the name
    /// comparison, so containment there is real extra evidence.
    public static func pageContainsSourceMPN(
        source: ProductIdentifiers, candidate: ProductIdentifiers, evidence: CandidatePageEvidence
    ) -> Bool {
        guard candidate.normalizedMPN == nil, let mpn = source.mpn else { return false }
        return containsNormalizedToken(mpn, in: [evidence.url?.absoluteString, evidence.html])
    }

    /// Full-profile-only relaxed name tier for a candidate that declares NO
    /// structured identifiers at all (no GTIN, MPN or SKU) when the source
    /// has one to check against. See the type-level doc's tier 5.
    ///
    /// The model-code check is URL/markup ONLY, for the same reason
    /// `pageContainsSourceMPN` is: the name has already been compared (at a
    /// HIGHER bar than usual, here) to reach this point, so re-checking the
    /// same cleaned name for a substring of ITSELF is not independent
    /// evidence — it is exactly what let two identically-named-but-unrelated
    /// products through in testing. The measured Costco case is unaffected:
    /// its URL contains the model code directly
    /// (`…/Hisense-634L-…-HRFD634BW/p/177525`).
    static func matchesByRelaxedNameWithModelCode(
        source: ProductIdentifiers, sourceName: String,
        candidate: ProductIdentifiers, candidateName: String,
        evidence: CandidatePageEvidence
    ) -> Bool {
        guard source.hasCrossHostIdentifier,
              candidate.gtin == nil, candidate.mpn == nil, candidate.sku == nil,
              ProductIdentityMatching.brandsCompatible(source.brand, candidate.brand)
        else { return false }
        let similarity = ProductIdentityMatching.nameSimilarity(
            ProductTitleHygiene.cleaned(sourceName), ProductTitleHygiene.cleaned(candidateName))
        guard similarity >= relaxedNameThreshold else { return false }
        guard let token = modelCodeToken(sourceName: sourceName, mpn: source.mpn) else { return true }
        return containsNormalizedToken(token, in: [evidence.url?.absoluteString, evidence.html])
    }

    /// The stricter name-similarity bar tier 5 asks for, in place of the
    /// ordinary 0.6 — it has no structured identifier to lean on at all, so it
    /// asks for more of the one signal it has.
    static let relaxedNameThreshold = 0.75

    /// The first model-code-like token (a mixed letter+digit run of 6+
    /// characters, e.g. `HRFD634BW`) in the MPN, else in the source name.
    /// Plain words and pure digit runs (already covered by the GTIN tier)
    /// don't qualify — this is specifically the kind of token a manufacturer
    /// model number is, which a retail listing's own title usually repeats
    /// verbatim even when nothing else on the page is machine-readable.
    static func modelCodeToken(sourceName: String, mpn: String?) -> String? {
        for text in [mpn, sourceName].compactMap({ $0 }) {
            if let token = modelCodeTokens(in: text).first { return token }
        }
        return nil
    }

    static func modelCodeTokens(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { token in
            token.count >= 6 && token.contains { $0.isLetter } && token.contains { $0.isNumber }
        }
    }

    /// Whether `raw`, normalized to uppercase alphanumerics, appears as a
    /// substring of any of `texts` (similarly normalized) — the shared
    /// "cheap string containment" check `pageContainsSourceMPN` and the
    /// relaxed name tier's model-code check both need. Below length 4 a token
    /// is not distinctive enough to be evidence of anything.
    static func containsNormalizedToken(_ raw: String, in texts: [String?]) -> Bool {
        guard let token = ProductIdentityMatching.normalizedID(raw), token.count >= 4 else { return false }
        for text in texts {
            guard let text, !text.isEmpty else { continue }
            let normalized = text.uppercased().filter { $0.isLetter || $0.isNumber }
            if normalized.contains(token) { return true }
        }
        return false
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

    /// Needles specific to Amazon's small (measured ~1.3KB) Akamai Bot
    /// Manager interstitial, served with an ordinary 200 for
    /// `amazon.com.au/s?k=<gtin>` (2026-08-09, intermittently — the same
    /// request sometimes serves the real search page). It carries none of
    /// `challengeNeedles`'s prose ("captcha", "unusual traffic", …) — it is
    /// pure `bm-verify` challenge JS — so it needed its own markers. Checked
    /// only under `smallPageMaximumLength`: a genuine product/search page is
    /// never this short, so even these otherwise-generic-sounding needles
    /// ("bm-verify" could theoretically appear in a URL param on a real page)
    /// are safe at this size.
    static let smallPageChallengeNeedles = [
        "bm-verify",
        "triggerinterstitialchallenge",
        "_sec/verify?provider=interstitial",
    ]

    /// Above this size, `smallPageChallengeNeedles` are not checked — see
    /// their doc comment.
    static let smallPageMaximumLength = 8_000

    public static func isBotWall(statusCode: Int, html: String) -> Bool {
        if blockedStatusCodes.contains(statusCode) { return true }
        let lowered = html.lowercased()
        if html.count <= smallPageMaximumLength,
           smallPageChallengeNeedles.contains(where: { lowered.contains($0) }) {
            return true
        }
        guard html.count <= maximumChallengeLength else { return false }
        return challengeNeedles.contains { lowered.contains($0) }
    }
}
