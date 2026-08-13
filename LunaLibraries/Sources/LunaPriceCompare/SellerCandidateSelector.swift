//
//  SellerCandidateSelector.swift
//  LunaPriceCompare
//

import Foundation
import LunaModels
import LunaPriceMetadata

/// A directory seller with the score that put it where it is in the ranking.
struct ScoredSeller: Equatable, Sendable {
    let seller: Seller
    let score: Int

    init(seller: Seller, score: Int) {
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
enum SellerCandidateSelector {

    /// Everything the ranking is a function of. Pure input — no clock, no
    /// locale lookup, no network — so a given `Input` always yields the same
    /// ordering.
    struct Input: Equatable, Sendable {
        /// Host of the page being saved (excluded from its own comparison).
        let sourceHost: String
        let identifiers: ProductIdentifiers
        let productName: String
        /// Free-text category evidence from the source page (JSON-LD
        /// `category`, breadcrumbs, …).
        let categoryHints: [String]
        /// Hosts already covered — the source, plus every store already on the
        /// tracker. Excluded by retailer FAMILY, not by exact host.
        let excludedHosts: [String]
        /// Two-letter region whose storefronts are eligible.
        let region: String
        /// Maximum candidates to return (the profile's candidate budget).
        let limit: Int
        /// Whether sellers whose search results only exist after client-side
        /// rendering are ineligible. True in a context that cannot render (the
        /// Safari appex): the candidate budget is six, and spending one of them
        /// on a page that is structurally empty is a slot the run never gets
        /// back.
        let excludesClientRenderedSearch: Bool

        init(
            sourceHost: String, identifiers: ProductIdentifiers, productName: String,
            categoryHints: [String] = [], excludedHosts: [String] = [],
            region: String, limit: Int, excludesClientRenderedSearch: Bool = false
        ) {
            self.sourceHost = sourceHost
            self.identifiers = identifiers
            self.productName = productName
            self.categoryHints = categoryHints
            self.excludedHosts = excludedHosts
            self.region = region
            self.limit = limit
            self.excludesClientRenderedSearch = excludesClientRenderedSearch
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
    /// A specialist that shares NO category with the product, when the product
    /// HAS a category, is not a shop that might stock it — it is a shop that
    /// definitely does not. Without this, a book fanned out to a pet store, a
    /// hardware chain, an auto-parts chain and a pharmacy, because tier alone
    /// put four tier-1 specialists (30 + verified) above every tier-2 bookshop
    /// (18 + overlap). Large enough that a tier-1 mismatch (34 → 12) sits below
    /// a tier-3 match (8 + 12 = 20), and never applied to a mass merchant,
    /// which by definition has no specialism to mismatch.
    static let unrelatedSpecialistPenalty = -22

    // MARK: - Region

    /// The market whose storefronts to search — derived from the STORE the user
    /// is looking at, never from the device locale (an `amazon.co.uk` save is a
    /// UK shopping trip regardless of where the phone is, and a phone on
    /// holiday must not redirect it): the directory's own region for a known
    /// retailer, else the country the host's TLD claims, else the region whose
    /// storefronts transact in the page's own declared currency, else `US`.
    static func resolveRegion(
        sourceHost: String, sourceCurrency: String? = nil, directory: SellerDirectory
    ) -> String {
        if let seller = directory.seller(forHost: sourceHost) { return seller.region.uppercased() }
        if let region = regionFromHostTLD(sourceHost), directory.regions.contains(region) {
            return region
        }
        if let currency = sourceCurrency?.uppercased(),
           let region = SellerDirectory.currencies.first(where: { $0.value == currency })?.key,
           directory.regions.contains(region) {
            return region
        }
        return "US"
    }

    /// Country TLD → directory region. Only the countries the directory has
    /// storefronts for; a country-neutral TLD (`.com`, `.net`) maps to nothing.
    static let tldRegions: [String: String] = [
        "uk": "GB", "gb": "GB", "au": "AU", "ca": "CA", "nz": "NZ",
        "ie": "IE", "in": "IN", "sg": "SG", "za": "ZA", "us": "US",
    ]

    /// The country a host's final label claims (`myer.com.au` → AU,
    /// `argos.co.uk` → GB), or nil when the TLD says nothing about a country.
    static func regionFromHostTLD(_ host: String) -> String? {
        guard let last = host.lowercased().split(separator: ".").last else { return nil }
        return tldRegions[String(last)]
    }

    // MARK: - Selection

    /// The ranked candidates for `input`, best first, at most `input.limit`.
    static func select(_ input: Input, in directory: SellerDirectory) -> [ScoredSeller] {
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
            if input.excludesClientRenderedSearch, seller.searchRequiresRendering { return false }
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
    static func score(_ seller: Seller, categories: Set<String>, hasGTIN: Bool) -> Int {
        var score = tierScores[seller.tier] ?? 0
        let overlap = categories.intersection(seller.categories).count
        score += min(overlap * categoryOverlapBonus, maximumCategoryBonus)
        if !categories.isEmpty, overlap == 0,
           !seller.categories.contains(SellerCategory.general.rawValue) {
            score += unrelatedSpecialistPenalty
        }
        if hasGTIN, seller.acceptsGTIN == true { score += acceptsGTINBonus }
        if seller.verified { score += verifiedBonus }
        if seller.marketplace, !hasGTIN { score += marketplaceWithoutGTINPenalty }
        return score
    }

    /// The query to search a given seller with: raw GTIN digits when the seller
    /// is known to accept them and we have one (an exact lookup), else the
    /// product name (a guess the match verifier still has to confirm).
    static func query(for seller: Seller, identifiers: ProductIdentifiers, productName: String)
        -> String {
        queries(for: seller, identifiers: identifiers, productName: productName)[0]
    }

    /// Every query worth trying on this seller, best first.
    ///
    /// A GTIN search is tried whenever we HAVE a GTIN and the directory does not
    /// say the seller refuses one — including when `acceptsGTIN` is `nil`,
    /// which means unknown rather than no. That is not optimism, it is the only
    /// way most candidates can ever be verified: when the source declares a
    /// GTIN, name-only matching is refused outright (it would be the accessory
    /// or the other edition), so a candidate reached by a NAME search can only
    /// pass if its page happens to publish structured identifiers — which, on
    /// the real web, most do not. Asking by identifier is what unlocks the
    /// `.gtinInPage` tier for it.
    ///
    /// The name is the fallback for the same candidate rather than a different
    /// candidate: a shop that does not index barcodes answers a GTIN search
    /// with an empty results page, and that costs one extra fetch to discover,
    /// against a whole retailer's price to skip it.
    static func queries(
        for seller: Seller, identifiers: ProductIdentifiers, productName: String
    ) -> [String] {
        let name = ProductTitleHygiene.cleaned(productName)
        guard seller.acceptsGTIN != false, let gtin = identifiers.gtin,
              !gtin.isEmpty, gtin.allSatisfy(\.isNumber)
        else { return [name] }
        // A seller KNOWN to accept barcodes is asked once. An empty answer from
        // one of those means "not stocked", and asking again by name would just
        // find a different product — while doubling this run's request rate at a
        // retailer, which is itself how a bot wall gets tripped.
        guard seller.acceptsGTIN == nil, !name.isEmpty else { return [gtin] }
        return [gtin, name]
    }
}
