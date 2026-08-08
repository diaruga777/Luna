//
//  LeanProductURLRules.swift
//  LunaPriceCompare
//

import Foundation

/// The retail URL SHAPES this module recognizes, and the two questions it asks
/// of a link found in a search-results page: does this look like one product,
/// and does it look like another listing grid?
///
/// This is a deliberate hand-copy of `ProductPageRules` +
/// `ProductPageDetector.urlLooksLikeProduct` / `.urlIsMultiProductListing`
/// (LunaHTMLClassification). That module links SwiftSoup and cannot go into the
/// Safari appex under its ~80MB ceiling, and this module's whole point is to be
/// linkable there — the same trade `SharedProductMatching` already makes on the
/// extension side. `LeanProductURLParityTests` pins the tables and the two
/// predicates to the originals, so the copy cannot drift silently.
public enum LeanProductURLRules {

    /// Regex syntax stays inside the subset both `NSRegularExpression` and
    /// JavaScript's `RegExp` support, matching the original.
    public static let productPathPatterns = [
        "_p[0-9]{4,}",
        "/dp/[A-Z0-9]{6,}",
        "/gp/product/",
        "/p/[0-9]{4,}",
        "/products/[^/]+",
        "/itm/[0-9]{4,}",
    ]

    public static let listingFirstPathSegments = [
        "s", "search", "sch", "b", "browse", "bestsellers",
        "deals", "stores", "category", "categories", "collections",
    ]

    public static let listingTwoSegmentPaths = [
        "gp/search", "gp/bestsellers", "gp/browse",
    ]

    public static let searchQueryParameterNames = [
        "k", "field-keywords", "q", "query", "keyword", "keywords", "searchterm",
    ]

    /// Whether the URL path matches a common retail product-page shape.
    public static func looksLikeProduct(_ url: URL?) -> Bool {
        guard let path = url?.path, !path.isEmpty else { return false }
        for pattern in productPathPatterns
        where path.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    /// URL shapes that list MANY products at equal primacy. A recognized
    /// single-product URL wins outright, exactly as in the original.
    public static func isMultiProductListing(_ url: URL?) -> Bool {
        guard let url else { return false }
        if looksLikeProduct(url) { return false }

        let segments = url.path.split(separator: "/").map { $0.lowercased() }
        if let first = segments.first, listingFirstPathSegments.contains(first) { return true }
        let firstTwo = segments.prefix(2).joined(separator: "/")
        if listingTwoSegmentPaths.contains(firstTwo) { return true }
        let searchParamNames = Set(searchQueryParameterNames)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return query.contains { searchParamNames.contains($0.name.lowercased()) }
    }
}
