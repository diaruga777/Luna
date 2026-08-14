//
//  SnapshotMatcher.swift
//  LunaPriceUI
//

import Foundation
import LunaHTMLClassification
import LunaModels
import LunaPriceCompare

/// Matches stored `ProductSnapshot`s against a product being saved, so a new
/// price tracker is born with the history Luna already observed
/// (`ProductTrackerMerge.seedHistoryFromSnapshots`). Pure and order-stable.
///
/// **Retrieval is by index, not by scan.** `candidateKeys` turns the product
/// into the identifier keys `ProductSnapshotStore` files observations under;
/// the store opens only those records; the tiers below then decide, over that
/// small pool, which of them really are the same product. The tiers exist
/// because the keys are a deliberate SUPERSET — the flattened `productID`
/// carries no record of which kind of id it is, so it is offered at every
/// scope and disqualified here.
///
/// Precedence, strongest signal first — the FIRST tier that matches ANY
/// snapshot wins outright (weaker tiers are not also folded in):
/// 1. GTIN/ISBN equality (zero-padded to 14 digits) — globally unique,
///    matches across hosts.
/// 2. `retailerItemID` equality, same retailer family (host suffix) — an
///    Amazon ASIN only matches an amazon.* host, etc.
/// 3. `mpn` equality + compatible brand — manufacturer-scoped.
/// 4. `sku` equality, same host only — retailer-scoped.
/// 5. Canonical URL equality (tracking params stripped both sides) against the
///    candidate's own URL or any store URL already on the tracker being merged
///    into. The weak tier, and the last one that is evidence of identity.
/// 6. Fuzzy NAME similarity (token Jaccard ≥ `ProductIdentityMatching
///    .nameThreshold`) with a compatible brand, within ONE retailer family or
///    ONE declared brand. Ranked below every tier above, so an identifier
///    always wins; reached only when tiers 1–4 matched nothing.
///
/// Tiers 1–4 win OUTRIGHT. Tiers 5 and 6 are UNIONED with each other rather
/// than ordered — see `identifierMatches` for why the URL tier cannot be
/// allowed to gate the name tier.
///
/// **Why the name tier exists, and why it is last.** A name is not an
/// identifier, and this tier is the one most likely to fold another product's
/// price into a graph — but the majority of retail pages declare no GTIN, MPN
/// or SKU at all, and the Safari extension files an observation under the
/// page's CANONICAL url while a later save is keyed by the url the user
/// actually saved. When those differ (a `?variant=`, a slug, a share link)
/// there is nothing else left, and the observation is unreachable forever. The
/// user's recovery for a wrong match is direct: removing the seller takes its
/// points off the graph and records the rejection (`PriceTracker
/// .rejectedSellerHosts`), so a bad fold is one long-press to undo and never
/// comes back.
///
/// **It is still a lookup, not a scan.** `ProductSnapshotKeys.nameKeys` files
/// every observation under its longest name tokens, scoped to its brand and to
/// its retailer family; a candidate asks the same shape and reads at most
/// `fuzzyCandidateLimit` records.
public enum SnapshotMatcher {

    /// The most snapshot rows a NAME lookup may read. A name bucket is a
    /// narrowed guess rather than an identifier hit, so it gets a hard ceiling
    /// on the save path — newest days first (decided from the index alone).
    public static let fuzzyCandidateLimit = 40

    /// The index keys to look this product up under — identifier tiers only.
    public static func candidateKeys(
        for candidate: ProductInfo, candidateURL: URL, existingStoreURLStrings: [String] = []
    ) -> [String] {
        ProductSnapshotKeys.candidateKeys(
            gtin: candidate.identifiers.gtin,
            mpn: candidate.identifiers.mpn,
            sku: candidate.identifiers.sku,
            flattenedID: candidate.productID,
            host: candidateURL.host,
            urlStrings: [candidateURL.absoluteString] + existingStoreURLStrings)
    }

    /// The name-bucket keys for the fuzzy tier, asked ONLY when every
    /// identifier tier came back empty. Scoped exactly as the tier is: this
    /// product's brand, and this page's retailer family.
    public static func nameCandidateKeys(
        for candidate: ProductInfo, candidateURL: URL
    ) -> [String] {
        ProductSnapshotKeys.nameKeys(
            candidate.name, brand: candidate.brand ?? candidate.identifiers.brand,
            host: candidateURL.host, limit: ProductSnapshotKeys.maxQueriedNameTokens)
    }

    /// The snapshots that should seed the saved product's tracker history, or
    /// `[]` if nothing matches at any tier. `existingStoreURLStrings` should
    /// include every store URL already on the tracker `candidate` is being
    /// merged into (empty for a brand-new tracker) — tier 5 matches against
    /// those too, not just `candidateURL`.
    public static func matchingSnapshots(
        for candidate: ProductInfo,
        candidateURL: URL,
        existingStoreURLStrings: [String] = [],
        among snapshots: [ProductSnapshot]
    ) -> [ProductSnapshot] {
        let identified = identifierMatches(
            for: candidate, candidateURL: candidateURL,
            existingStoreURLStrings: existingStoreURLStrings, among: snapshots)
        guard identified.isEmpty else { return identified }
        return merged(
            urlMatches(
                for: candidateURL, existingStoreURLStrings: existingStoreURLStrings,
                among: snapshots),
            fuzzyNameMatches(for: candidate, candidateURL: candidateURL, among: snapshots))
    }

    /// Tiers 1–4 — every tier that decides identity from an IDENTIFIER. Empty
    /// when none matched, which is the only condition under which the URL and
    /// NAME tiers are consulted.
    ///
    /// **The URL tier is deliberately NOT in here**, even though it is stronger
    /// than a name. It cannot gate the name tier, because on the save path it
    /// is always satisfied by the candidate's own page: ingestion records an
    /// observation of the page it is classifying *before* it seeds the tracker
    /// from the store, so "tier 5 matched" reduces to "we just wrote a row for
    /// this URL" and no observation of the same product anywhere else could
    /// ever be reached. The two weak tiers are therefore UNIONED (below)
    /// instead of ordered against each other: one contributes this page's own
    /// earlier days, the other other sellers of the same product.
    public static func identifierMatches(
        for candidate: ProductInfo,
        candidateURL: URL,
        existingStoreURLStrings: [String] = [],
        among snapshots: [ProductSnapshot]
    ) -> [ProductSnapshot] {
        // Sorted once, up front, so every tier below folds its matches in a
        // fixed order regardless of the pool's order.
        let pool = snapshots.sorted {
            $0.day != $1.day ? $0.day < $1.day : $0.url < $1.url
        }
        let candidateHost = candidateURL.host?.lowercased()
        let candidateNormalizedID = ProductMatcher.normalizedID(candidate.productID)

        // 1. GTIN/ISBN — cross-host. Prefers the KEYED identifier when the
        // candidate declares one; falls back to the flattened id when it does
        // not, so a candidate saved before `ProductIdentifiers` existed matches
        // exactly as it always has.
        let candidateKeyedGTIN = ProductMatcher.normalizedID(candidate.identifiers.gtin)
        if let candidateGTIN = normalizedGTIN(candidateKeyedGTIN ?? candidateNormalizedID) {
            let matches = pool.filter {
                guard let gtin = normalizedGTIN(ProductMatcher.normalizedID($0.gtin))
                else { return false }
                return gtin == candidateGTIN
            }
            if !matches.isEmpty { return matches }
        }

        // 2. retailerItemID — same retailer family only.
        if let candidateNormalizedID, let candidateHost {
            let matches = pool.filter { snapshot in
                guard let retailerID = ProductMatcher.normalizedID(snapshot.retailerItemID),
                      retailerID == candidateNormalizedID,
                      let snapshotHost = URL(string: snapshot.url)?.host?.lowercased()
                        ?? nonEmpty(snapshot.host)?.lowercased()
                else { return false }
                return hostFamilyMatches(candidateHost, snapshotHost)
            }
            if !matches.isEmpty { return matches }
        }

        // 3. mpn — requires a compatible brand. Prefers the keyed `mpn`,
        // falling back to the flattened id.
        let candidateKeyedMPN = ProductMatcher.normalizedID(candidate.identifiers.mpn)
        if let candidateMPNID = candidateKeyedMPN ?? candidateNormalizedID {
            let matches = pool.filter { snapshot in
                guard let mpn = ProductMatcher.normalizedID(snapshot.mpn), mpn == candidateMPNID
                else { return false }
                return ProductMatcher.brandsCompatible(candidate.brand, snapshot.brand)
            }
            if !matches.isEmpty { return matches }
        }

        // 4. sku — same host only. Prefers the keyed `sku`, falling back to
        // the flattened id.
        let candidateKeyedSKU = ProductMatcher.normalizedID(candidate.identifiers.sku)
        if let candidateSKUID = candidateKeyedSKU ?? candidateNormalizedID, let candidateHost {
            let matches = pool.filter { snapshot in
                guard let sku = ProductMatcher.normalizedID(snapshot.sku), sku == candidateSKUID
                else { return false }
                return snapshot.host.lowercased() == candidateHost
            }
            if !matches.isEmpty { return matches }
        }

        return []
    }

    /// Tier 5 — canonical URL equality (tracking params stripped both sides)
    /// against the candidate's own URL or any store URL already on the tracker
    /// being merged into.
    public static func urlMatches(
        for candidateURL: URL, existingStoreURLStrings: [String] = [],
        among snapshots: [ProductSnapshot]
    ) -> [ProductSnapshot] {
        let strippedTargets = Set(
            ([candidateURL.absoluteString] + existingStoreURLStrings)
                .map(ProductSnapshotKeys.strippedTrackingURL))
        return snapshots
            .sorted { $0.day != $1.day ? $0.day < $1.day : $0.url < $1.url }
            .filter { strippedTargets.contains(ProductSnapshotKeys.strippedTrackingURL($0.url)) }
    }

    /// The two weak tiers' union, deduplicated on an observation's identity
    /// (its page and its day) and in the same order every tier returns.
    public static func merged(
        _ lhs: [ProductSnapshot], _ rhs: [ProductSnapshot]
    ) -> [ProductSnapshot] {
        var seen = Set<String>()
        return (lhs + rhs)
            .filter { seen.insert("\($0.url)|\($0.day.text)").inserted }
            .sorted { $0.day != $1.day ? $0.day < $1.day : $0.url < $1.url }
    }

    /// Tier 6 — the fuzzy NAME tier, and the last resort. An observation
    /// qualifies when its name overlaps the candidate's past
    /// `ProductIdentityMatching.nameThreshold`, its brand is compatible, and it
    /// is in scope: the same retailer family, or the same explicitly declared
    /// brand. The scope is not decoration — it is the same narrowing the index
    /// keys apply, so a hand-supplied pool cannot match wider than a lookup
    /// would have retrieved.
    ///
    /// Order-stable (by day, then url, like every tier), and it returns EVERY
    /// qualifying observation rather than a single best: a name match that
    /// holds for one day's price holds for the rest of that seller's history.
    public static func fuzzyNameMatches(
        for candidate: ProductInfo, candidateURL: URL, among snapshots: [ProductSnapshot]
    ) -> [ProductSnapshot] {
        guard !candidate.name.isEmpty else { return [] }
        let candidateHost = candidateURL.host?.lowercased()
        let candidateBrand = ProductIdentityMatching.comparableBrand(
            candidate.brand ?? candidate.identifiers.brand)
        return snapshots
            .sorted { $0.day != $1.day ? $0.day < $1.day : $0.url < $1.url }
            .filter { snapshot in
                guard ProductMatcher.brandsCompatible(candidate.brand, snapshot.brand) else {
                    return false
                }
                let sameFamily = candidateHost.map {
                    hostFamilyMatches($0, snapshot.host.lowercased())
                } ?? false
                let sameBrand = candidateBrand != nil
                    && candidateBrand == ProductIdentityMatching.comparableBrand(snapshot.brand)
                guard sameFamily || sameBrand else { return false }
                return ProductIdentityMatching.nameSimilarity(candidate.name, snapshot.name)
                    >= ProductIdentityMatching.nameThreshold
            }
    }

    /// Zero-pads a purely-numeric id to 14 digits (the GTIN-14 numberspace
    /// GTIN-8/12/13/14 all share at different widths) so ids of different
    /// declared widths still compare equal. A non-numeric value (e.g. an
    /// ISBN-10 with a check letter) compares as-is.
    static func normalizedGTIN(_ raw: String?) -> String? {
        ProductIdentityMatching.normalizedGTIN(raw)
    }

    /// Two hosts are the same "retailer family" when they share a registrable
    /// domain, so `www.amazon.com` and `smile.amazon.com` match but
    /// `amazon.com` and `amazon.co.jp` do NOT (a retailer item id is not
    /// guaranteed to carry across separate national storefronts).
    static func hostFamilyMatches(_ lhs: String, _ rhs: String) -> Bool {
        ProductIdentityMatching.hostFamilyMatches(lhs, rhs)
    }

    static func strippedTrackingURL(_ urlString: String) -> String {
        ProductSnapshotKeys.strippedTrackingURL(urlString)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
