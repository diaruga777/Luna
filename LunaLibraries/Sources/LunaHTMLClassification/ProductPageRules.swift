//
//  ProductPageRules.swift
//  LunaHTMLClassification
//

/// Declarative product-page evidence shared by the Swift classifier and Safari.
///
/// Swift is the source of truth. `ProductPageRulesJSParityTests` records these values
/// into `LunaSafari/Resources/product_rules.generated.js`, and fails when that artifact
/// is stale. `content.js` consumes only the generated values instead of maintaining a
/// second hand-copied rule table.
public enum ProductPageRules {
    public static let minimumHeuristicScore = 2

    public static let productOpenGraphTypes = ["product", "product.item"]
    public static let productPriceMetaNames = [
        "product:price:amount", "og:price:amount", "product:price",
    ]

    /// Regex syntax is deliberately limited to the common subset supported by both
    /// `NSRegularExpression` and JavaScript's `RegExp`.
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

    public static let addToCartPhrases = ["add to cart", "add to bag"]
    public static let addToCartMarkupNeedles = ["addtocart"]
    public static let ratingMarkupNeedles = [
        "aggregaterating", "ratingvalue", "out of 5", "star rating",
    ]
}
