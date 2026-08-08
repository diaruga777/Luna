//
//  SellerCandidateSelector.swift
//  LunaPriceCompare
//

import Foundation
import LunaModels

/// A directory seller with the score that put it where it is in the ranking.
public struct ScoredSeller: Equatable, Sendable {
    public let seller: Seller
    public let score: Int

    public init(seller: Seller, score: Int) {
        self.seller = seller
        self.score = score
    }
}

/// Picks — locally, deterministically, with no network — which retailers are
/// worth asking about a given product, and in what order.
///
/// This is the whole reason the fan-out is affordable: rather than searching a
/// directory of 200-odd retailers, it searches at most a dozen, chosen so the
/// ones most likely to stock the product and to answer a bot-free request come
/// first. Candidates are deliberately OVER-provisioned relative to the result
/// target, because a bot wall on a tier-1 retailer is an expected outcome, not
/// an error (`claudedocs/price-comparison.md`).
public enum SellerCandidateSelector {

    /// Everything the ranking is a function of. Pure input — no clock, no
    /// locale lookup, no network — so a given `Input` always yields the same
    /// ordering.
    public struct Input: Equatable, Sendable {
        /// Host of the page being saved (excluded from its own comparison).
        public let sourceHost: String
        public let identifiers: ProductIdentifiers
        public let productName: String
        /// Free-text category evidence from the source page (JSON-LD
        /// `category`, breadcrumbs, …).
        public let categoryHints: [String]
        /// Hosts already covered — the source, plus every store already on the
        /// tracker. Excluded by retailer FAMILY, not by exact host.
        public let excludedHosts: [String]
        /// Two-letter region whose storefronts are eligible.
        public let region: String
        /// Maximum candidates to return (the profile's candidate budget).
        public let limit: Int

        public init(
            sourceHost: String, identifiers: ProductIdentifiers, productName: String,
            categoryHints: [String] = [], excludedHosts: [String] = [],
            region: String, limit: Int
        ) {
            self.sourceHost = sourceHost
            self.identifiers = identifiers
            self.productName = productName
            self.categoryHints = categoryHints
            self.excludedHosts = excludedHosts
            self.region = region
            self.limit = limit
        }
    }

    // MARK: - Scoring weights

    /// A household name is worth far more than a niche shop: it is likelier to
    /// stock the product at all, and its page is likelier to be parseable.
    static let tierScores: [Int: Int] = [1: 30, 2: 18, 3: 8]
    static let categoryOverlapBonus = 12
    static let maximumCategoryBonus = 24
    /// Searching by GTIN is an exact lookup; searching by name is a guess.
    static let acceptsGTINBonus = 10
    static let verifiedBonus = 4
    /// Name matching on a marketplace is noisy — third-party listings retitle
    /// the same product freely — so without a GTIN to anchor on, prefer
    /// first-party retailers.
    static let marketplaceWithoutGTINPenalty = -8

    // MARK: - Region

    /// The region whose storefronts to search: the source retailer's own region
    /// when the directory knows it (an `amazon.co.uk` save is a UK shopping
    /// trip regardless of where the phone is), else the device's region, else
    /// `US`.
    public static func resolveRegion(
        sourceHost: String, directory: SellerDirectory, localeRegion: String?
    ) -> String {
        if let seller = directory.seller(forHost: sourceHost) { return seller.region.uppercased() }
        if let localeRegion, localeRegion.count == 2 {
            let candidate = localeRegion.uppercased()
            if directory.regions.contains(candidate) { return candidate }
        }
        return "US"
    }

    // MARK: - Selection

    /// The ranked candidates for `input`, best first, at most `input.limit`.
    public static func select(_ input: Input, in directory: SellerDirectory) -> [ScoredSeller] {
        let excludedDomains = Set(
            ([input.sourceHost] + input.excludedHosts)
                .filter { !$0.isEmpty }
                .map(ProductIdentityMatching.registrableDomain))

        let sourceCategories = directory.seller(forHost: input.sourceHost)?.categories ?? []
        let categories = SellerCategoryInference.categories(
            hints: input.categoryHints,
            productName: input.productName,
            sourceCategories: sourceCategories)
        let hasGTIN = input.identifiers.normalizedGTIN != nil

        let eligible = directory.sellers(inRegion: input.region).filter { seller in
            guard !excludedDomains.contains(
                ProductIdentityMatching.registrableDomain(seller.domain)) else { return false }
            // Nothing suggests a category ⇒ ask the shops that sell everything,
            // rather than a dozen specialists chosen at random.
            if categories.isEmpty {
                return seller.categories.contains(SellerCategory.general.rawValue)
            }
            return true
        }

        let scored = eligible.map {
            ScoredSeller(seller: $0, score: score($0, categories: categories, hasGTIN: hasGTIN))
        }
        // Deterministic total order: score desc, then tier asc, then id asc.
        // The id tiebreak is what keeps two equal-scoring sellers from swapping
        // places between runs (or between the app and the Safari appex).
        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.seller.tier != rhs.seller.tier { return lhs.seller.tier < rhs.seller.tier }
            return lhs.seller.id < rhs.seller.id
        }
        .prefix(max(0, input.limit))
        .map { $0 }
    }

    /// The deterministic score for one seller. Public so the weights can be
    /// asserted directly rather than inferred from an ordering.
    public static func score(_ seller: Seller, categories: Set<String>, hasGTIN: Bool) -> Int {
        var score = tierScores[seller.tier] ?? 0
        let overlap = categories.intersection(seller.categories).count
        score += min(overlap * categoryOverlapBonus, maximumCategoryBonus)
        if hasGTIN, seller.acceptsGTIN == true { score += acceptsGTINBonus }
        if seller.verified { score += verifiedBonus }
        if seller.marketplace, !hasGTIN { score += marketplaceWithoutGTINPenalty }
        return score
    }

    /// The query to search a given seller with: raw GTIN digits when the seller
    /// is known to accept them and we have one (an exact lookup), else the
    /// product name (a guess the match verifier still has to confirm).
    public static func query(for seller: Seller, identifiers: ProductIdentifiers, productName: String)
        -> String {
        if seller.acceptsGTIN == true, let gtin = identifiers.gtin,
           !gtin.isEmpty, gtin.allSatisfy(\.isNumber) {
            return gtin
        }
        return productName
    }
}
