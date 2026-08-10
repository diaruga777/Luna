//
//  ProductIdentifiers.swift
//  LunaModels
//

import Foundation

/// The KEYED product identifiers a product page declares — the cross-seller
/// "is this the same product?" evidence.
///
/// Why keyed, when `ProductInfo.productID` / `PriceTracker.productID` already
/// carry ONE flattened string: the flattened value throws away which KIND of id
/// it is, and the kinds have completely different scopes. A GTIN is globally
/// unique and matches across retailers (the whole basis of the alternative-seller
/// fan-out); an MPN is manufacturer-scoped and only trustworthy alongside a
/// compatible brand; an SKU is retailer-scoped and means nothing on another host.
/// Comparing a flattened id against every keyed field in turn (what
/// `SnapshotMatcher` has to do) is a workaround for the loss, not a design.
///
/// The flattened fields stay for backwards compatibility — every persisted
/// tracker written before this type existed has one, and nothing has migrated.
public struct ProductIdentifiers: Codable, Equatable, Hashable, Sendable {
    /// GTIN/UPC/EAN/ISBN — globally unique, matches ACROSS hosts.
    public var gtin: String?
    /// Manufacturer part number — manufacturer-scoped; needs a compatible brand.
    public var mpn: String?
    /// Retailer stock-keeping unit — meaningful only on the host that declared it.
    public var sku: String?
    /// Brand / manufacturer name.
    public var brand: String?

    public init(gtin: String? = nil, mpn: String? = nil, sku: String? = nil, brand: String? = nil) {
        self.gtin = Self.trimmed(gtin)
        self.mpn = Self.trimmed(mpn)
        self.sku = Self.trimmed(sku)
        self.brand = Self.trimmed(brand)
    }

    /// True when nothing at all was declared (the common case for a heuristic
    /// Tier-2 product page).
    public var isEmpty: Bool { gtin == nil && mpn == nil && sku == nil && brand == nil }

    /// The GTIN reduced to its comparable form (see
    /// `ProductIdentityMatching.normalizedGTIN`), or nil.
    public var normalizedGTIN: String? {
        ProductIdentityMatching.normalizedGTIN(ProductIdentityMatching.normalizedID(gtin))
    }

    /// The MPN reduced to comparable alphanumerics, or nil.
    public var normalizedMPN: String? { ProductIdentityMatching.normalizedID(mpn) }

    /// The retailer SKU reduced to comparable alphanumerics, or nil.
    public var normalizedSKU: String? { ProductIdentityMatching.normalizedID(sku) }

    /// Whether this carries any identifier strong enough to match across hosts
    /// (a GTIN, or an MPN that a brand can qualify).
    public var hasCrossHostIdentifier: Bool { normalizedGTIN != nil || normalizedMPN != nil }

    /// Fills this value's EMPTY fields from `other`; never overwrites a field
    /// that is already set. Used to fold a flattened legacy id, or a second
    /// extraction pass, into a keyed set without losing the stronger source.
    public func merging(_ other: ProductIdentifiers) -> ProductIdentifiers {
        ProductIdentifiers(
            gtin: gtin ?? other.gtin,
            mpn: mpn ?? other.mpn,
            sku: sku ?? other.sku,
            brand: brand ?? other.brand)
    }

    private static func trimmed(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// The small, pure normalization primitives the "same product?" decision is
/// built from, at the LOWEST tier so every consumer can share one copy: the
/// keyed comparison engine (`LunaPriceCompare`), which must stay linkable by the
/// Safari appexes, and the SwiftSoup-backed matchers above it.
///
/// `ProductMatcher` / `SnapshotMatcher` (LunaHTMLClassification) keep their own
/// long-standing copies — they are load-bearing for the existing save/merge and
/// snapshot-seeding paths and are not worth churning — but
/// `ComparisonMatchingParityTests` pins these definitions to theirs, so the two
/// can never diverge silently.
public enum ProductIdentityMatching {
    /// Token-overlap fraction at/above which two product names are "the same".
    public static let nameThreshold = 0.6

    /// A product id reduced for comparison (uppercased alphanumerics) so cosmetic
    /// punctuation/casing differences (`SKU-1` vs `sku1`) don't defeat a match.
    public static func normalizedID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Zero-pads a purely-numeric id to 14 digits (the GTIN-14 numberspace
    /// GTIN-8/12/13/14 all share at different widths) so ids of different
    /// declared widths still compare equal. A non-numeric value (e.g. an
    /// ISBN-10 with a check letter) compares as-is.
    public static func normalizedGTIN(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard raw.allSatisfy(\.isNumber), raw.count <= 14 else { return raw }
        return String(repeating: "0", count: 14 - raw.count) + raw
    }

    /// Brands match when they're equal (case-insensitive) OR at least one side is
    /// unknown — an unbranded listing shouldn't block an otherwise strong match.
    public static func brandsCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = normalizedBrand(lhs), let rhs = normalizedBrand(rhs) else { return true }
        return lhs == rhs
    }

    /// Jaccard token overlap of two normalized product names (0…1). Tokens are
    /// lowercased alphanumeric words with stop-words removed.
    public static func nameSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = tokens(lhs)
        let rhsTokens = tokens(rhs)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }
        return Double(lhsTokens.intersection(rhsTokens).count)
            / Double(lhsTokens.union(rhsTokens).count)
    }

    /// The registrable domain of a host — approximated as the last two
    /// dot-separated labels, or the last three when the second-to-last label is a
    /// known compound suffix (`co.uk`, `com.au`, …). `www.amazon.com` and
    /// `smile.amazon.com` share one; `amazon.com` and `amazon.co.uk` do not.
    public static func registrableDomain(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return host.lowercased() }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if labels.count >= 3, compoundSuffixes.contains(lastTwo) {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    /// Whether two hosts belong to the same retailer family.
    public static func hostFamilyMatches(_ lhs: String, _ rhs: String) -> Bool {
        registrableDomain(lhs) == registrableDomain(rhs)
    }

    private static let compoundSuffixes: Set<String> = [
        "co.uk", "co.jp", "co.nz", "co.in", "com.au", "com.br", "com.mx", "com.tr",
    ]

    /// Common marketing words that shouldn't drive a same-product decision.
    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "with", "for", "new", "of", "in", "to",
        "buy", "shop", "online", "official", "store",
    ]

    private static func tokens(_ name: String) -> Set<String> {
        Set(name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopWords.contains($0) })
    }

    private static func normalizedBrand(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? nil : cleaned
    }
}
