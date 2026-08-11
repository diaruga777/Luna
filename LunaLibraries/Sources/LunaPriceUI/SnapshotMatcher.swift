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
///    into. The weak tier, and the last one.
///
/// There is deliberately NO fuzzy-name tier. A name is not an identifier: it
/// cannot be indexed, so it would force the scan this design exists to avoid,
/// and it is the tier most likely to fold another product's price into a graph.
public enum SnapshotMatcher {

    /// The index keys to look this product up under.
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

        // 5. Canonical URL equality against the candidate or any existing store.
        let strippedTargets = Set(
            ([candidateURL.absoluteString] + existingStoreURLStrings)
                .map(ProductSnapshotKeys.strippedTrackingURL))
        return pool.filter {
            strippedTargets.contains(ProductSnapshotKeys.strippedTrackingURL($0.url))
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
