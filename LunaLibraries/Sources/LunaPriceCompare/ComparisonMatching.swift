//
//  ComparisonMatching.swift
//  LunaPriceCompare
//

import Foundation
import LunaModels

/// How strongly a candidate seller page was matched to the source product.
/// Ordered, because the merge rule lets a better-verified result for the same
/// retailer supplant a weaker one.
public enum SellerMatchConfidence: Int, Comparable, Codable, Sendable {
    /// Fuzzy product-name overlap plus a compatible brand — only accepted when
    /// the source itself declared no cross-host identifier at all.
    case name = 0
    /// Manufacturer part number equality with a compatible brand.
    case mpn = 1
    /// GTIN equality — the same physical product, by definition.
    case gtin = 2

    public static func < (lhs: SellerMatchConfidence, rhs: SellerMatchConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
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
/// 3. Jaccard name similarity ≥ `ProductIdentityMatching.nameThreshold` with a
///    compatible brand → accept, but ONLY when name matching is enabled for
///    this profile AND the source declared no GTIN or MPN. If the source has a
///    strong id and the candidate does not present the same one, a name
///    coincidence is not evidence — it is the accessory, the older model, or
///    the two-pack.
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
        guard allowsNameOnlyMatch, !source.hasCrossHostIdentifier else { return nil }
        guard ProductIdentityMatching.brandsCompatible(source.brand, candidate.brand),
              ProductIdentityMatching.nameSimilarity(sourceName, candidateName)
                >= ProductIdentityMatching.nameThreshold
        else { return nil }
        return .name
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
