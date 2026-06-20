//
//  ProductMatcher.swift
//  Clip
//

import Foundation

/// Pure logic for deciding whether a freshly detected product is the SAME
/// product as an existing tracker — so a new save can be offered as a merge.
///
/// Matching, strongest signal first:
/// 1. `productID` (GTIN/SKU/…) equality — identical ids are the same product.
/// 2. Fuzzy name+brand similarity above `nameThreshold` — normalized token
///    Jaccard, requiring a compatible brand (same brand, or one side unbranded).
enum ProductMatcher {
    /// Token-overlap fraction at/above which two product names are "the same".
    static let nameThreshold = 0.6

    /// Finds the best existing tracker that matches `candidate`, if any.
    /// `existing` pairs each tracker's stable id with its product info.
    static func bestMatch(
        for candidate: ProductInfo,
        among existing: [(id: UUID, tracker: PriceTracker)]
    ) -> UUID? {
        // 1) Exact product-id match wins outright.
        if let candidateID = normalizedID(candidate.productID) {
            for entry in existing where normalizedID(entry.tracker.productID) == candidateID {
                return entry.id
            }
        }
        // 2) Fuzzy name+brand match — keep the highest-scoring compatible one.
        var best: (id: UUID, score: Double)?
        for entry in existing {
            guard brandsCompatible(candidate.brand, entry.tracker.brand) else { continue }
            let score = nameSimilarity(candidate.name, entry.tracker.productName)
            guard score >= nameThreshold else { continue }
            if best == nil || score > best!.score { best = (entry.id, score) }
        }
        return best?.id
    }

    /// A product id reduced for comparison (uppercased alphanumerics) so cosmetic
    /// punctuation/casing differences (`SKU-1` vs `sku1`) don't defeat a match.
    static func normalizedID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Brands match when they're equal (case-insensitive) OR at least one side is
    /// unknown — an unbranded listing shouldn't block an otherwise strong name match.
    static func brandsCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = lhs?.normalizedForMatching, !lhs.isEmpty,
              let rhs = rhs?.normalizedForMatching, !rhs.isEmpty else { return true }
        return lhs == rhs
    }

    /// Jaccard token overlap of two normalized product names (0…1). Tokens are
    /// lowercased alphanumeric words with stop-words removed.
    static func nameSimilarity(_ lhs: String, _ rhs: String) -> Double {
        let lhsTokens = tokens(lhs)
        let rhsTokens = tokens(rhs)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return 0 }
        let intersection = lhsTokens.intersection(rhsTokens)
        let union = lhsTokens.union(rhsTokens)
        return Double(intersection.count) / Double(union.count)
    }

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
}

private extension String {
    /// Lowercased alphanumerics only — for brand equality comparisons.
    var normalizedForMatching: String {
        lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
