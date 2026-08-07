//
//  SnapshotMatcher.swift
//  Luna
//

import LunaModels
import Foundation

/// Matches passive `ProductSnapshot`s (Safari extension captures) against a
/// freshly saved product, so `ProductTrackerIngestor` can seed the new (or
/// merged) tracker's per-store history without waiting for a background
/// refresh. Pure and order-stable.
///
/// Precedence, strongest signal first — the FIRST tier that matches ANY
/// snapshot wins outright (weaker tiers are not also folded in):
/// 1. GTIN/ISBN equality (zero-padded to 14 digits) — globally unique,
///    matches across hosts.
/// 2. `retailerItemID` equality, same retailer family (host suffix) — an
///    Amazon ASIN only matches an amazon.* host, etc. The candidate's raw
///    `productID` participates here too (`ProductMatcher.normalizedID`).
/// 3. `mpn` equality + compatible brand — manufacturer-scoped.
/// 4. `sku` equality, same host only — retailer-scoped.
/// 5. Canonical URL equality (tracking params stripped both sides) against
///    the candidate's own URL or any store URL already on the tracker being
///    merged into.
/// 6. Fuzzy name (`ProductMatcher.nameSimilarity >= nameThreshold`) + brand
///    compatibility.
///
/// This is the same identifier family `ProductPageDetector.productID(from:offer:)`
/// flattens into `ProductInfo.productID` (gtin13/12/14/8/gtin/isbn/mpn/sku/
/// productID, first match wins) — so a saved product's ONE raw id is compared
/// against every KEYED snapshot field in turn, at whichever tier that field
/// belongs to.
public enum SnapshotMatcher {

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
        // fixed order regardless of the snapshot file's on-disk order.
        let pool = snapshots.sorted {
            $0.day != $1.day ? $0.day < $1.day : $0.url < $1.url
        }
        let candidateHost = candidateURL.host?.lowercased()
        let candidateNormalizedID = ProductMatcher.normalizedID(candidate.productID)

        // 1. GTIN/ISBN — cross-host.
        if let candidateGTIN = normalizedGTIN(candidateNormalizedID) {
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

        // 3. mpn — requires a compatible brand.
        if let candidateNormalizedID {
            let matches = pool.filter { snapshot in
                guard let mpn = ProductMatcher.normalizedID(snapshot.mpn), mpn == candidateNormalizedID
                else { return false }
                return ProductMatcher.brandsCompatible(candidate.brand, snapshot.brand)
            }
            if !matches.isEmpty { return matches }
        }

        // 4. sku — same host only.
        if let candidateNormalizedID, let candidateHost {
            let matches = pool.filter { snapshot in
                guard let sku = ProductMatcher.normalizedID(snapshot.sku), sku == candidateNormalizedID
                else { return false }
                return snapshot.host.lowercased() == candidateHost
            }
            if !matches.isEmpty { return matches }
        }

        // 5. Canonical URL equality against the candidate or any existing store.
        let strippedTargets = Set(
            ([candidateURL.absoluteString] + existingStoreURLStrings).map(strippedTrackingURL))
        let urlMatches = pool.filter { strippedTargets.contains(strippedTrackingURL($0.url)) }
        if !urlMatches.isEmpty { return urlMatches }

        // 6. Fuzzy name + compatible brand.
        return pool.filter { snapshot in
            ProductMatcher.brandsCompatible(candidate.brand, snapshot.brand)
                && ProductMatcher.nameSimilarity(candidate.name, snapshot.name) >= ProductMatcher.nameThreshold
        }
    }

    /// Zero-pads a purely-numeric id to 14 digits (the GTIN-14 numberspace
    /// GTIN-8/12/13/14 all share at different widths) so ids of different
    /// declared widths still compare equal. A non-numeric value (e.g. an
    /// ISBN-10 with a check letter) compares as-is.
    static func normalizedGTIN(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard raw.allSatisfy(\.isNumber), raw.count <= 14 else { return raw }
        return String(repeating: "0", count: 14 - raw.count) + raw
    }

    /// Two hosts are the same "retailer family" when they share a registrable
    /// domain — approximated as the last two dot-separated labels, or the
    /// last three when the second-to-last label is a known compound suffix
    /// (`co.uk`, `com.au`, …), so `www.amazon.com` and `smile.amazon.com`
    /// match but `amazon.com` and `amazon.co.jp` do NOT (a retailer item id
    /// is not guaranteed to carry across separate national storefronts, and
    /// treating them as one family would let an unrelated site match by
    /// coincidence far more often than it would help).
    static func hostFamilyMatches(_ lhs: String, _ rhs: String) -> Bool {
        registrableDomain(lhs) == registrableDomain(rhs)
    }

    private static let compoundSuffixes: Set<String> = [
        "co.uk", "co.jp", "co.nz", "co.in", "com.au", "com.br", "com.mx", "com.tr",
    ]

    static func registrableDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return host.lowercased() }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if labels.count >= 3, compoundSuffixes.contains(lastTwo) {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    /// Strips the same tracking-parameter families the extension strips at
    /// capture time (`stripTrackingParams` in content.js) before comparing two
    /// URLs, so query noise picked up between the snapshot and the save can't
    /// defeat an otherwise-identical page URL.
    static func strippedTrackingURL(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else { return urlString }
        let host = (components.host ?? "").lowercased()
        components.queryItems = components.queryItems?.filter { item in
            let lower = item.name.lowercased()
            if ["srsltid", "gclid", "ref"].contains(lower) { return false }
            if lower.hasPrefix("utm_") { return false }
            if lower == "tag", host.contains("amazon.") { return false }
            return true
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url?.absoluteString ?? urlString
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
