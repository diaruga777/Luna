//
//  ProductPageDetector.swift
//  Luna
//

import LunaModels
import LunaURLClassification
import Foundation
import SwiftSoup

/// A numeric price + its ISO 4217 currency. The price is the load-bearing value
/// of the whole price-tracking feature, so it is always a real, non-negative
/// amount with a known currency — never nil/pending.
public struct ProductPrice: Equatable {
    /// The numeric price. Always non-negative.
    public let amount: Decimal
    /// ISO 4217 currency code, uppercased (e.g. "USD", "GBP").
    public let currency: String

    public init(amount: Decimal, currency: String) {
        self.amount = amount
        self.currency = currency
    }
}

/// One seller/store listing for an aggregate shopping page. The URL is the
/// seller's own product page, never the aggregate/search page.
public struct ProductSellerInfo: Equatable {
    public let url: URL
    public let price: ProductPrice

    public init(url: URL, price: ProductPrice) {
        self.url = url
        self.price = price
    }
}

/// A purchasable product detected on a saved web page, paired with a price that
/// was successfully fetched up front. The price is REQUIRED: a `ProductInfo` only
/// exists once a real price is in hand (see `PriceFetcher`), so a price tracker
/// can never be created without one.
public struct ProductInfo: Equatable {
    /// Product display name (the page's product title).
    public let name: String
    /// The numeric price. Always non-negative.
    public let priceAmount: Decimal
    /// ISO 4217 currency code, uppercased (e.g. "USD", "GBP").
    public let priceCurrency: String
    /// Best product image, if one was found.
    public let imageURL: URL?
    /// Brand / manufacturer, if declared.
    public let brand: String?
    /// A stable product identifier (GTIN/UPC/EAN/ISBN/MPN/SKU), if declared —
    /// FLATTENED to one string, so which kind of id it is has been lost. Kept for
    /// the existing match/merge paths; prefer `identifiers` for new matching.
    public let productID: String?
    /// The KEYED identifiers the page declared. Unlike `productID` these keep
    /// their scope (`ProductIdentifiers`), which is what makes a cross-seller
    /// comparison possible: only a GTIN travels between retailers.
    public let identifiers: ProductIdentifiers
    /// Seller listings discovered on an aggregate shopping page. Empty for ordinary
    /// single-store product pages, where the processed URL itself is the seller.
    public let sellers: [ProductSellerInfo]

    /// Builds the priced product from a detected candidate and a fetched price.
    public init(candidate: ProductCandidate, price: ProductPrice) {
        self.name = candidate.name
        self.priceAmount = price.amount
        self.priceCurrency = price.currency
        self.imageURL = candidate.imageURL
        self.brand = candidate.brand
        self.productID = candidate.productID
        self.identifiers = candidate.identifiers
        self.sellers = []
    }

    /// Direct initializer (used by the structured-data path that already has all
    /// fields, and by tests).
    public init(
        name: String, priceAmount: Decimal, priceCurrency: String,
        imageURL: URL?, brand: String?, productID: String?,
        identifiers: ProductIdentifiers = ProductIdentifiers(),
        sellers: [ProductSellerInfo] = []
    ) {
        self.name = name
        self.priceAmount = priceAmount
        self.priceCurrency = priceCurrency
        self.imageURL = imageURL
        self.brand = brand
        self.productID = productID
        self.identifiers = identifiers
        self.sellers = sellers
    }
}

/// A page that has been classified as a product page, with its descriptive
/// metadata and whatever price (if any) could be parsed from the *static* markup.
///
/// A candidate is NOT yet a tracker: detection decides "this is a product"; the
/// mandatory price fetch (`PriceFetcher`) decides whether it becomes a tracker. A
/// candidate from structured data (Tier 1) always carries a `staticPrice`; a
/// heuristic candidate (Tier 2) may have a `staticPrice` recovered from embedded
/// app-state JSON, or none (the price is only in the rendered DOM and must be
/// fetched via the WKWebView fallback).
public struct ProductCandidate: Equatable {
    public let name: String
    /// The price found in the static markup (structured data or embedded JSON), if
    /// any. Nil ⇒ the price is rendered client-side and needs the WebView fallback.
    public let staticPrice: ProductPrice?
    public let imageURL: URL?
    public let brand: String?
    public let productID: String?
    /// The keyed identifiers the page declared, kept alongside the flattened
    /// `productID` so a cross-seller comparison can tell a GTIN from an SKU.
    public var identifiers: ProductIdentifiers = ProductIdentifiers()
}

/// Pure detection of whether a saved page is a purchasable *product page*. Given a
/// URL + its HTML, returns a `ProductCandidate` when the page is a product, else
/// nil. No I/O, no UIKit — fully fixture-testable.
///
/// Detection answers "is this a product?" and reports any price it can read from
/// the static markup; it deliberately does NOT gate on a price (a heuristic
/// candidate may have its price only in the rendered DOM). The mandatory price
/// fetch (`PriceFetcher`) decides whether a candidate becomes a tracker.
///
/// Two tiers, in order of trust:
///
/// **Tier 1 — structured price data (highest confidence).** A page that declares
/// a price in machine-readable markup is unambiguously a product, so a single hit
/// is enough (and the candidate always carries a `staticPrice`):
/// 1. JSON-LD `Product`/`Offer` (`offers.price` + `priceCurrency`) — recursing
///    `@graph` / arrays / nested offers, like the article extractor's JSON-LD walk.
/// 2. OpenGraph product meta (`product:price:amount` / `og:price:amount` + currency).
/// 3. schema.org microdata (`itemprop="price"` + `itemprop="priceCurrency"`).
/// 4. Common bare price meta (`product:price`).
///
/// **Tier 2 — heuristic detection (no structured price).** Retailers that render
/// price client-side expose no structured price, so we score combinable signals
/// and call it a product when **≥2 strong signals** are present (see
/// `heuristicProductScore`). When detected this way we still try to recover a price
/// from embedded app-state JSON (`__NEXT_DATA__` / `<script type=application/json>`
/// / `window.__…` blobs); if none is parseable the candidate's `staticPrice` is nil
/// and the price must be fetched from the rendered DOM (WKWebView fallback).
public struct ProductPageDetector {
    public init() {}

    /// Returns a product candidate if `html` describes a product page.
    public func detect(urlString: String, html: String) -> ProductCandidate? {
        let baseURL = URL(string: urlString)
        guard let document = try? SwiftSoup.parse(html, urlString) else { return nil }
        return detect(document: document, baseURL: baseURL)
    }

    /// Whether the page carries TIER-1 structured price markup (JSON-LD `Product`
    /// / OpenGraph product meta / schema.org microdata) — the unambiguous "this is a
    /// product" signal. Used by `Classifier` to tell a trusted structured hit apart
    /// from a fuzzy Tier-2 heuristic hit (so a news page with a stray affordance is
    /// never misclassified). Pure.
    public func hasStructuredProductData(document: Document, baseURL: URL?) -> Bool {
        // A listing grid can emit per-card structured offers; those describe the
        // grid's items, not a single primary product, so never a product page.
        if Self.urlIsMultiProductListing(baseURL) { return false }
        if candidateFromJSONLD(document: document, baseURL: baseURL) != nil { return true }
        return priceFromMetaOrMicrodata(document: document) != nil
    }

    /// The descriptive metadata fields (name/image/brand/id) for a parsed product
    /// page — the single place those fields come from, reused by
    /// `ProductMetadataExtractor` so detection and extraction agree on them.
    public func metadataFields(
        document: Document, baseURL: URL?
    ) -> (name: String, imageURL: URL?, brand: String?, productID: String?,
          identifiers: ProductIdentifiers) {
        let brandName = brand(document: document)
        // JSON-LD is richer than microdata when both are present, so prefer its
        // keyed values and let microdata fill any gap.
        let identifiers = jsonLDIdentifiers(document: document)
            .merging(microdataIdentifiers(document: document, brand: brandName))
        return (name: productName(document: document, baseURL: baseURL),
                imageURL: productImage(document: document, baseURL: baseURL),
                brand: brandName,
                productID: microdataProductID(document: document),
                identifiers: identifiers)
    }

    /// The GENERIC structured price — JSON-LD `Offer`, OpenGraph `product:price`,
    /// schema.org microdata, then embedded app-state JSON — with NO retailer-specific
    /// logic. The fallback `ProductMetadataExtractor` consults when no per-host rule
    /// matches. Pure.
    public func genericStructuredPrice(document: Document, baseURL: URL?) -> ProductPrice? {
        if let price = priceFromMetaOrMicrodata(document: document) { return price }
        if let candidate = candidateFromJSONLD(document: document, baseURL: baseURL),
           let price = candidate.staticPrice {
            return price
        }
        return priceFromEmbeddedJSON(document: document)
    }

    /// Detection over an already-parsed document (lets the article pipeline reuse
    /// a parse it already has).
    public func detect(document: Document, baseURL: URL?) -> ProductCandidate? {
        // A search / browse / category grid lists MANY products at equal primacy —
        // never a single product page, regardless of the per-card retail furniture
        // (add-to-cart buttons, star ratings, even per-item offers) it carries.
        if Self.urlIsMultiProductListing(baseURL) { return nil }

        // Tier 1: structured price data — the richest, most reliable source.
        if let candidate = candidateFromJSONLD(document: document, baseURL: baseURL) {
            return candidate
        }
        if let price = priceFromMetaOrMicrodata(document: document) {
            let brandName = brand(document: document)
            return ProductCandidate(
                name: productName(document: document, baseURL: baseURL),
                staticPrice: price,
                imageURL: productImage(document: document, baseURL: baseURL),
                brand: brandName,
                productID: microdataProductID(document: document),
                identifiers: jsonLDIdentifiers(document: document)
                    .merging(microdataIdentifiers(document: document, brand: brandName)))
        }

        // Tier 2: no structured price — score heuristic signals. A single product
        // page with a price but no Tier-1 markup (Bunnings, Amazon /dp/) is caught
        // here; the listing-URL veto above already excludes multi-product grids, so
        // Tier 2 stays a standalone product classifier.
        let (score, embeddedPrice) = heuristicProductScore(document: document, baseURL: baseURL)
        guard score >= Self.minimumHeuristicScore else { return nil }
        let brandName = brand(document: document)
        return ProductCandidate(
            name: productName(document: document, baseURL: baseURL),
            staticPrice: embeddedPrice,
            imageURL: productImage(document: document, baseURL: baseURL),
            brand: brandName,
            productID: microdataProductID(document: document),
            identifiers: jsonLDIdentifiers(document: document)
                .merging(microdataIdentifiers(document: document, brand: brandName)))
    }

    /// Resolves the price visible in the STATIC markup (Tier 1 structured data,
    /// then Tier 2 embedded app-state JSON), independent of whether the page is a
    /// product. The `PriceFetcher` calls this for its fast, no-WebView paths; a nil
    /// result means the price (if any) is only in the rendered DOM.
    public func staticPrice(urlString: String, html: String) -> ProductPrice? {
        guard let document = try? SwiftSoup.parse(html, urlString) else { return nil }
        if let price = priceFromMetaOrMicrodata(document: document) { return price }
        if let candidate = candidateFromJSONLD(document: document, baseURL: URL(string: urlString)),
           let price = candidate.staticPrice {
            return price
        }
        if let price = priceFromEmbeddedJSON(document: document) { return price }
        // Amazon renders the price into the static markup but exposes no structured
        // price node — recover it from Amazon's embedded shapes (with a TLD currency
        // fallback when none is declared).
        return Self.amazonStaticPrice(html: html, baseURL: URL(string: urlString))
    }

    // MARK: - Amazon static price (Tier 2 retailer-specific)

    /// Amazon product pages embed the price directly in the STATIC markup but
    /// without a JSON-LD/OG/microdata price node. The amount appears as the JSON
    /// fragment `"priceAmount":<number>` / `"displayPrice":"$…"` (Amazon's price
    /// model) and as the visible `.a-price .a-offscreen` span. We read the amount
    /// from those shapes and resolve the currency from a declared
    /// `currencyCode`/`priceCurrency`, else from the Amazon TLD (so a bare `$`
    /// resolves to e.g. AUD on amazon.com.au rather than defaulting to USD). Pure.
    public static func amazonStaticPrice(html: String, baseURL: URL?) -> ProductPrice? {
        guard isAmazonHost(baseURL?.host) else { return nil }
        let currency = amazonDeclaredCurrency(html: html)
            ?? amazonCurrency(forHost: baseURL?.host)
            ?? "USD"

        // 1) `"priceAmount":39.99` — the structured price in Amazon's price model.
        if let raw = RegexCapture.first(in: html, pattern: #""priceAmount"\s*:\s*([0-9]+(?:\.[0-9]+)?)"#),
           let amount = parsePrice(raw), amount >= 0 {
            return ProductPrice(amount: amount, currency: currency)
        }
        // 2) `"displayPrice":"$39.99"` — the formatted price string.
        if let raw = RegexCapture.first(in: html, pattern: #""displayPrice"\s*:\s*"([^"]+)""#),
           let amount = parsePrice(raw), amount >= 0 {
            return ProductPrice(amount: amount, currency: currency)
        }
        // 3) The visible `.a-price .a-offscreen` span ("$39.99").
        if let raw = RegexCapture.first(in: html, pattern: #"a-offscreen"\s*>\s*([^<]*[0-9][^<]*)<"#),
           let amount = parsePrice(raw), amount >= 0 {
            return ProductPrice(amount: amount, currency: currency)
        }
        return nil
    }

    /// True ONLY for a real Amazon storefront (`amazon.com`, `amazon.com.au`,
    /// `www.amazon.co.za`, …). The shared registry rejects lookalikes such as
    /// `amazon.scam.com` and keeps static-price parsing aligned with classification.
    private static func isAmazonHost(_ host: String?) -> Bool {
        AmazonStorefronts.storefront(for: host) != nil
    }

    /// A currency explicitly declared in Amazon's embedded price JSON
    /// (`"currencyCode":"AUD"` / `"priceCurrency":"USD"`), if present.
    private static func amazonDeclaredCurrency(html: String) -> String? {
        for key in ["currencyCode", "priceCurrency"] {
            if let raw = RegexCapture.first(in: html, pattern: #""\#(key)"\s*:\s*"([A-Za-z]{3})""#),
               let code = normalizeCurrency(raw) {
                return code
            }
        }
        return nil
    }

    /// Maps an Amazon storefront TLD to its currency, the fallback when the markup
    /// declares no currency code (a bare `$`/`£`/… symbol can't disambiguate AUD vs
    /// USD vs CAD). Deterministic.
    public static func amazonCurrency(forHost host: String?) -> String? {
        AmazonStorefronts.storefront(for: host)?.currency
    }

    // MARK: - Heuristic detection (Tier 2)

    /// A page is treated as a product when it shows at least this many strong
    /// signals. Two is deliberate: any single signal (a stray "add to cart" link in
    /// a nav, a `/p/` path) is too weak to reclassify an article, but two
    /// independent retail signals together reliably mean a product page.
    public static let minimumHeuristicScore = ProductPageRules.minimumHeuristicScore

    /// Scores the combinable retail signals on a page that has no structured price,
    /// and (as a side effect, since it must scan the page's scripts anyway) returns
    /// any price recovered from embedded app-state JSON.
    ///
    /// Strong signals, each worth 1:
    /// - `og:type == product`
    /// - an "add to cart" / `addToCart` affordance (button text or a JS handler)
    /// - a star/aggregate rating (`aggregateRating` / `ratingValue` / "out of 5" /
    ///   "Star Rating")
    /// - a retail URL pattern (`_p<digits>`, `/dp/<id>`, `/p/<digits>`,
    ///   `/products/<slug>`, `/itm/<id>`)
    /// - a price+currency recovered from embedded app-state JSON
    public func heuristicProductScore(document: Document, baseURL: URL?) -> (score: Int, embeddedPrice: ProductPrice?) {
        var score = 0

        let ogType = metaContent(document, names: ["og:type"])?.lowercased()
        if let ogType, ProductPageRules.productOpenGraphTypes.contains(ogType) { score += 1 }

        if hasAddToCartAffordance(document: document) { score += 1 }
        if hasRatingSignal(document: document) { score += 1 }
        if Self.urlLooksLikeProduct(baseURL) { score += 1 }

        let embeddedPrice = priceFromEmbeddedJSON(document: document)
        if embeddedPrice != nil { score += 1 }

        return (score, embeddedPrice)
    }

    /// Whether the page exposes an add-to-cart affordance: visible "add to cart"
    /// text on a button/link, or an `addToCart` JS handler / data attribute (which
    /// retail SPAs wire up even before the button text renders).
    private func hasAddToCartAffordance(document: Document) -> Bool {
        if let buttons = try? document.select("button, a, [role=button], input[type=submit]") {
            for element in buttons {
                let text = ((try? element.text()) ?? "").lowercased()
                if ProductPageRules.addToCartPhrases.contains(where: text.contains) { return true }
                let value = ((try? element.attr("value")) ?? "").lowercased()
                if ProductPageRules.addToCartPhrases.contains(where: value.contains) { return true }
            }
        }
        // Fall back to the raw markup: SPA handlers (`onClick={addToCart}`,
        // `data-testid="addToCart"`) and inline state name the action even when the
        // button text is rendered later by JS.
        let html = (try? document.html()) ?? ""
        return ProductPageRules.addToCartMarkupNeedles.contains {
            html.range(of: $0, options: .caseInsensitive) != nil
        }
    }

    /// Whether the page shows a product rating: schema rating attributes, a
    /// `ratingValue`, or visible "out of 5" / "Star Rating" copy.
    private func hasRatingSignal(document: Document) -> Bool {
        if (try? document.select("[itemprop=aggregateRating], [itemprop=ratingValue]").first()) ?? nil != nil {
            return true
        }
        let html = (try? document.html()) ?? ""
        for needle in ProductPageRules.ratingMarkupNeedles {
            if html.range(of: needle, options: .caseInsensitive) != nil { return true }
        }
        return false
    }

    /// URL shapes that list MANY products at equal primacy — search results,
    /// browse/category nodes, best-seller and deals grids. A single primary product
    /// never lives at such a URL, so these are never a product page regardless of the
    /// per-card retail furniture (add-to-cart buttons, star ratings, even per-item
    /// structured offers) they carry. The primary guard against the "several products,
    /// one pill" bug — e.g. an Amazon `/s?k=…` search page. Mirrored in
    /// `content.js` (`urlIsMultiProductListing`); keep the two in sync.
    public static func urlIsMultiProductListing(_ url: URL?) -> Bool {
        guard let url else { return false }
        // A recognized single-product URL wins — never treat it as a listing even if
        // a stray listing token appears elsewhere in the path.
        if urlLooksLikeProduct(url) { return false }

        let segments = url.path.split(separator: "/").map { $0.lowercased() }
        // Search / browse / category / deals path segments (Amazon `/s`, `/b`; eBay
        // `/sch`; generic `/search`, `/category`, `/collections`, …).
        let listingSegments = Set(ProductPageRules.listingFirstPathSegments)
        if let first = segments.first, listingSegments.contains(first) { return true }
        let firstTwo = segments.prefix(2).joined(separator: "/")
        if ProductPageRules.listingTwoSegmentPaths.contains(firstTwo) {
            return true
        }
        // A search query parameter (`?k=`/`?field-keywords=` Amazon, `?q=`/`?query=`/…).
        let searchParamNames = Set(ProductPageRules.searchQueryParameterNames)
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if query.contains(where: { searchParamNames.contains($0.name.lowercased()) }) { return true }
        return false
    }

    /// Whether the URL path matches a common retail product-page shape.
    public static func urlLooksLikeProduct(_ url: URL?) -> Bool {
        guard let path = url?.path, !path.isEmpty else { return false }
        // `_p0208315` (Bunnings/SAP Hybris), `/dp/B09…` (Amazon), `/p/123` (Target/
        // Best Buy), `/products/slug` (Shopify), `/itm/123` (eBay).
        for pattern in ProductPageRules.productPathPatterns
        where path.range(of: pattern, options: .regularExpression) != nil {
            return true
        }
        return false
    }

    // MARK: - Embedded app-state JSON price (Tier 2)

    /// Price-context keys that, when sitting alongside a numeric value, identify it
    /// as a price (rather than some unrelated number in the app state).
    private static let priceValueKeys = [
        "sellprice", "nowprice", "saleprice", "currentprice", "price", "value", "amount",
    ]
    private static let priceContextKeys = [
        "priceavailable", "pricetype", "pricecurrency", "currencyiso", "currencycode",
        "currency", "sellprice", "nowprice", "saleprice", "formattedvalue",
    ]
    private static let currencyKeys = [
        "pricecurrency", "currencyiso", "currencycode", "currency",
    ]

    /// Scans the page's embedded JSON blobs (`__NEXT_DATA__`, any
    /// `<script type="application/json">`, and inline `window.__…={…}` assignments)
    /// for a price anchored to a price-context key, plus its currency. Returns the
    /// first plausible hit. Pure.
    public func priceFromEmbeddedJSON(document: Document) -> ProductPrice? {
        for blob in embeddedJSONBlobs(document: document) {
            guard let data = blob.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let price = Self.firstPrice(in: parsed) { return price }
        }
        return nil
    }

    /// All candidate JSON strings on the page: `__NEXT_DATA__` first (richest), then
    /// other `application/json` scripts, then inline `window.__X__ = { … };` blobs.
    private func embeddedJSONBlobs(document: Document) -> [String] {
        var blobs = EmbeddedJSONBlobs.nextDataAndJSONScripts(in: document)
        // Inline state assignments: `window.__APOLLO_STATE__ = {…};`,
        // `window.__INITIAL_STATE__ = {…}`. Pull the object literal after the `=`.
        let inlineScriptSelector = "script:not([type]), script[type=\"text/javascript\"], "
            + "script[type=\"application/javascript\"]"
        if let scripts = try? document.select(inlineScriptSelector) {
            for script in scripts {
                let body = (try? script.html()) ?? ""
                guard body.range(of: "window.__", options: .caseInsensitive) != nil else { continue }
                if let object = Self.firstJSONObjectLiteral(in: body) { blobs.append(object) }
            }
        }
        return blobs
    }

    /// Extracts the first balanced `{ … }` object literal from a JS source string
    /// (an inline `window.__STATE__ = { … }` assignment). Returns nil if no balanced
    /// object is found.
    public static func firstJSONObjectLiteral(in source: String) -> String? {
        guard let start = source.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < source.endIndex {
            let character = source[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 {
                        return String(source[start...index])
                    }
                default: break
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// Recursively searches parsed JSON for the first object that carries both a
    /// price-context key and a usable numeric value + currency. Pure + static so it's
    /// directly unit-testable on a dictionary.
    ///
    /// Child objects are visited in **sorted-key order**, never raw dictionary order:
    /// Swift `Dictionary` iteration is hash-seed randomized per process, so two
    /// price-bearing nodes in the same tree would otherwise resolve to different
    /// prices on different app launches — the exact non-determinism the price-tracking
    /// feature must not have. Sorted traversal makes the recovered price a pure
    /// function of the JSON content.
    public static func firstPrice(in object: Any) -> ProductPrice? {
        if let dictionary = object as? [String: Any] {
            if let price = price(inDictionary: dictionary) { return price }
            for key in dictionary.keys.sorted() {
                if let value = dictionary[key], let found = firstPrice(in: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = firstPrice(in: value) { return found }
            }
        }
        return nil
    }

    /// A price drawn from a single JSON object, IF it looks like a price node: it
    /// must carry at least one price-context key (so we don't pick up arbitrary
    /// `value`/`amount` numbers), a parseable numeric amount, and a resolvable
    /// currency (a sibling currency key, or one inferred from a `formattedValue`
    /// symbol). Returns nil otherwise.
    private static func price(inDictionary dictionary: [String: Any]) -> ProductPrice? {
        // Lowercase the keys for case-insensitive lookup. Two original keys can
        // collide on lowercasing (e.g. "Price" and "price"); resolve the collision by
        // keeping the original key that sorts first, so the winner is deterministic
        // rather than dependent on hash-seed-randomized dictionary order.
        var lowercasedKeys: [String: Any] = [:]
        for key in dictionary.keys.sorted() {
            let lowered = key.lowercased()
            if lowercasedKeys[lowered] == nil { lowercasedKeys[lowered] = dictionary[key] }
        }

        let hasPriceContext = priceContextKeys.contains { lowercasedKeys[$0] != nil }
        guard hasPriceContext else { return nil }

        guard let amount = amount(from: lowercasedKeys), amount >= 0 else { return nil }
        guard let currency = currency(from: lowercasedKeys) else { return nil }
        return ProductPrice(amount: amount, currency: currency)
    }

    private static func amount(from lowercasedKeys: [String: Any]) -> Decimal? {
        for key in priceValueKeys {
            guard let raw = lowercasedKeys[key] else { continue }
            if let number = raw as? NSNumber { return Decimal(string: number.stringValue) }
            if let string = raw as? String, let parsed = parsePrice(string) { return parsed }
        }
        // Last resort: a `formattedValue` string like "$99.00".
        if let formatted = lowercasedKeys["formattedvalue"] as? String,
           let parsed = parsePrice(formatted) {
            return parsed
        }
        return nil
    }

    private static func currency(from lowercasedKeys: [String: Any]) -> String? {
        for key in currencyKeys {
            guard let raw = lowercasedKeys[key] else { continue }
            if let string = raw as? String, let code = normalizeCurrency(string) { return code }
            // Common commerce state nests the ISO code under the currency field:
            // `{"currency":{"code":"AUD","symbol":"$"},"value":49.9}`.
            // Accept the generic shape rather than teaching the extractor a retailer.
            if let dictionary = raw as? [String: Any] {
                var nested: [String: Any] = [:]
                for nestedKey in dictionary.keys.sorted() {
                    let lowered = nestedKey.lowercased()
                    if nested[lowered] == nil { nested[lowered] = dictionary[nestedKey] }
                }
                for nestedKey in ["code", "currencycode", "isocode", "iso"] {
                    if let string = nested[nestedKey] as? String,
                       let code = normalizeCurrency(string) {
                        return code
                    }
                }
            }
        }
        // Infer from a `formattedValue` symbol ("$99.00" → USD).
        if let formatted = lowercasedKeys["formattedvalue"] as? String,
           let symbol = formatted.first(where: { "$£€¥".contains($0) }),
           let code = normalizeCurrency(String(symbol)) {
            return code
        }
        return nil
    }

    // MARK: - JSON-LD (Tier 1)

    private func candidateFromJSONLD(document: Document, baseURL: URL?) -> ProductCandidate? {
        guard let scripts = try? document.select("script[type=application/ld+json]") else {
            return nil
        }
        for script in scripts {
            guard let data = script.data().data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let node = firstProductNode(in: parsed),
               let candidate = Self.candidate(fromProductNode: node, document: document, baseURL: baseURL) {
                return candidate
            }
        }
        return nil
    }

    /// Finds the first JSON-LD node whose `@type` is (or includes) `Product`,
    /// recursing through `@graph` arrays and nested objects. Child objects are visited
    /// in **sorted-key order** (not raw dictionary order, which is hash-seed
    /// randomized per process) so a graph with more than one Product node always
    /// resolves to the same node — keeping detection deterministic across launches.
    private func firstProductNode(in object: Any) -> [String: Any]? {
        if let dictionary = object as? [String: Any] {
            if Self.typeContains(dictionary["@type"], "Product") { return dictionary }
            for key in dictionary.keys.sorted() {
                if let value = dictionary[key], let found = firstProductNode(in: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = firstProductNode(in: value) { return found }
            }
        }
        return nil
    }

    /// Whether a JSON-LD `@type` value (string or array of strings) equals `target`.
    private static func typeContains(_ value: Any?, _ target: String) -> Bool {
        if let string = value as? String { return string.caseInsensitiveCompare(target) == .orderedSame }
        if let array = value as? [Any] {
            return array.contains { ($0 as? String)?.caseInsensitiveCompare(target) == .orderedSame }
        }
        return false
    }

    /// Pure assembly of a `ProductCandidate` from a parsed JSON-LD `Product` node.
    /// Internal (not private) so it's directly unit-testable on a dictionary. A
    /// JSON-LD product always carries a structured price, so the candidate's
    /// `staticPrice` is non-nil.
    public static func candidate(
        fromProductNode node: [String: Any], document: Document?, baseURL: URL?
    ) -> ProductCandidate? {
        guard let offer = firstOffer(in: node),
              let (amount, currency) = price(fromOffer: offer) else { return nil }

        let name = (node["name"] as? String)?.trimmedNonEmpty
            ?? document.flatMap { ProductPageDetector().productName(document: $0, baseURL: baseURL) }
            ?? L10n.string("Common_productLabel")

        let image = imageURL(from: node["image"], baseURL: baseURL)
        let brand = brandName(from: node["brand"])
        let productID = self.productID(from: node, offer: offer)

        return ProductCandidate(
            name: name, staticPrice: ProductPrice(amount: amount, currency: currency),
            imageURL: image, brand: brand, productID: productID,
            identifiers: identifiers(from: node, offer: offer, brand: brand))
    }

    /// The KEYED identifiers of a JSON-LD `Product` node — the same family
    /// `productID(from:offer:)` flattens, but each kind kept in its own slot.
    /// `productID` itself is deliberately NOT folded in: it is an unqualified
    /// "some id" whose scope the page never states, so promoting it to a GTIN
    /// (which matches across retailers) would invent evidence.
    static func identifiers(
        from node: [String: Any], offer: [String: Any], brand: String?
    ) -> ProductIdentifiers {
        ProductIdentifiers(
            gtin: firstStringValue(
                in: [node, offer], keys: ["gtin13", "gtin12", "gtin14", "gtin8", "gtin", "isbn"]),
            mpn: firstStringValue(in: [node, offer], keys: ["mpn"]),
            sku: firstStringValue(in: [node, offer], keys: ["sku"]),
            brand: brand)
    }

    private static func firstStringValue(in sources: [[String: Any]], keys: [String]) -> String? {
        for source in sources {
            for key in keys {
                if let value = (source[key] as? String)?.trimmedNonEmpty { return value }
                if let number = source[key] as? NSNumber { return number.stringValue }
            }
        }
        return nil
    }

    /// The first offer object under a Product node — `offers` may be a single
    /// object, an array, or an `AggregateOffer` wrapping `offers`/`lowPrice`.
    private static func firstOffer(in node: [String: Any]) -> [String: Any]? {
        guard let offers = node["offers"] else {
            // Some feeds put price directly on the product node.
            return node["price"] != nil ? node : nil
        }
        if let dictionary = offers as? [String: Any] {
            // AggregateOffer: prefer its nested offers, else use it directly
            // (lowPrice/price live on the aggregate).
            if let nested = dictionary["offers"], let inner = firstOfferValue(nested) {
                return inner
            }
            return dictionary
        }
        if let inner = firstOfferValue(offers) { return inner }
        return nil
    }

    private static func firstOfferValue(_ value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        if let array = value as? [Any] { return array.compactMap { $0 as? [String: Any] }.first }
        return nil
    }

    /// Extracts `(amount, currency)` from an offer dict, honoring `price`,
    /// `lowPrice`, `priceSpecification.price`, and the matching currency field.
    private static func price(fromOffer offer: [String: Any]) -> (Decimal, String)? {
        var rawPrice = offer["price"] ?? offer["lowPrice"]
        var rawCurrency = offer["priceCurrency"]
        if let spec = offer["priceSpecification"] as? [String: Any] {
            rawPrice = rawPrice ?? spec["price"]
            rawCurrency = rawCurrency ?? spec["priceCurrency"]
        }
        guard let amount = decimal(fromJSON: rawPrice), amount >= 0 else { return nil }
        let currency = normalizeCurrency(rawCurrency as? String) ?? "USD"
        return (amount, currency)
    }

    private static func decimal(fromJSON value: Any?) -> Decimal? {
        if let string = value as? String { return parsePrice(string) }
        if let number = value as? NSNumber { return Decimal(string: number.stringValue) }
        return nil
    }

    private static func imageURL(from value: Any?, baseURL: URL?) -> URL? {
        let string: String?
        if let direct = value as? String {
            string = direct
        } else if let array = value as? [Any] {
            string = array.compactMap { $0 as? String }.first
                ?? (array.compactMap { $0 as? [String: Any] }.first?["url"] as? String)
        } else if let dictionary = value as? [String: Any] {
            string = dictionary["url"] as? String
        } else {
            string = nil
        }
        guard let string, let resolved = resolveURL(string, baseURL: baseURL) else { return nil }
        return resolved
    }

    private static func brandName(from value: Any?) -> String? {
        if let string = value as? String { return string.trimmedNonEmpty }
        if let dictionary = value as? [String: Any] {
            return (dictionary["name"] as? String)?.trimmedNonEmpty
        }
        return nil
    }

    /// GTIN/UPC/EAN/ISBN/MPN/SKU from the product node (preferred) or its offer.
    private static func productID(from node: [String: Any], offer: [String: Any]) -> String? {
        let keys = ["gtin13", "gtin12", "gtin14", "gtin8", "gtin",
                    "isbn", "mpn", "sku", "productID"]
        for source in [node, offer] {
            for key in keys {
                if let value = (source[key] as? String)?.trimmedNonEmpty { return value }
                if let number = source[key] as? NSNumber { return number.stringValue }
            }
        }
        return nil
    }

    // MARK: - Meta / microdata (Tier 1)

    private func priceFromMetaOrMicrodata(document: Document) -> ProductPrice? {
        // OpenGraph / product meta.
        let amountKeys = ProductPageRules.productPriceMetaNames
        let currencyKeys = ["product:price:currency", "og:price:currency", "product:currency"]
        if let raw = metaContent(document, names: amountKeys),
           let amount = Self.parsePrice(raw), amount >= 0 {
            let currency = Self.normalizeCurrency(metaContent(document, names: currencyKeys)) ?? "USD"
            return ProductPrice(amount: amount, currency: currency)
        }
        // schema.org microdata.
        if let raw = itempropValue(document, "price"),
           let amount = Self.parsePrice(raw), amount >= 0 {
            let currency = Self.normalizeCurrency(itempropValue(document, "priceCurrency")) ?? "USD"
            return ProductPrice(amount: amount, currency: currency)
        }
        return nil
    }

    private func microdataProductID(document: Document) -> String? {
        for prop in ["gtin13", "gtin12", "gtin14", "gtin8", "gtin", "sku", "mpn", "productID"] {
            if let value = itempropValue(document, prop)?.trimmedNonEmpty { return value }
        }
        return nil
    }

    /// The KEYED schema.org microdata identifiers — the microdata counterpart of
    /// `identifiers(from:offer:brand:)`.
    private func microdataIdentifiers(document: Document, brand: String?) -> ProductIdentifiers {
        func first(_ props: [String]) -> String? {
            for prop in props {
                if let value = itempropValue(document, prop)?.trimmedNonEmpty { return value }
            }
            return nil
        }
        return ProductIdentifiers(
            gtin: first(["gtin13", "gtin12", "gtin14", "gtin8", "gtin", "isbn"]),
            mpn: first(["mpn"]),
            sku: first(["sku"]),
            brand: brand)
    }

    /// The keyed identifiers of the page's first JSON-LD `Product` node,
    /// independent of whether that node carries a price — a per-host price rule
    /// (Amazon/Target/Walmart) can win the price while JSON-LD is still the only
    /// place the GTIN is stated.
    private func jsonLDIdentifiers(document: Document) -> ProductIdentifiers {
        guard let scripts = try? document.select("script[type=application/ld+json]") else {
            return ProductIdentifiers()
        }
        for script in scripts {
            guard let data = script.data().data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data),
                  let node = firstProductNode(in: parsed) else { continue }
            let identifiers = Self.identifiers(
                from: node, offer: Self.firstOffer(in: node) ?? [:],
                brand: Self.brandName(from: node["brand"]))
            if !identifiers.isEmpty { return identifiers }
        }
        return ProductIdentifiers()
    }

    private func brand(document: Document) -> String? {
        if let value = itempropValue(document, "brand")?.trimmedNonEmpty { return value }
        return metaContent(document, names: ["product:brand", "og:brand"])?.trimmedNonEmpty
    }

    // MARK: - Shared field helpers

    private func productName(document: Document, baseURL: URL?) -> String {
        if let itemprop = itempropValue(document, "name")?.trimmedNonEmpty { return itemprop }
        if let og = metaContent(document, names: ["og:title", "twitter:title"])?.trimmedNonEmpty { return og }
        if let title = (try? document.title())?.trimmedNonEmpty { return title }
        return baseURL?.host?.replacingOccurrences(of: "www.", with: "")
            ?? L10n.string("Common_productLabel")
    }

    private func productImage(document: Document, baseURL: URL?) -> URL? {
        guard let raw = metaContent(document, names: ["og:image", "twitter:image", "product:image"])
        else {
            if let microImage = itempropValue(document, "image") {
                return Self.resolveURL(microImage, baseURL: baseURL)
            }
            return nil
        }
        return Self.resolveURL(raw, baseURL: baseURL)
    }

    /// First non-empty `<meta>` content matching any of `names` (tried against
    /// both `property` and `name` attributes).
    private func metaContent(_ document: Document, names: [String]) -> String? {
        for name in names {
            for attribute in ["property", "name"] {
                if let element = try? document.select("meta[\(attribute)=\(name)]").first(),
                   let content = try? element.attr("content").trimmedNonEmpty {
                    return content
                }
            }
        }
        return nil
    }

    /// First `itemprop="<prop>"` value — its `content` attribute if present
    /// (meta-style), else its visible text.
    private func itempropValue(_ document: Document, _ prop: String) -> String? {
        guard let element = try? document.select("[itemprop=\(prop)]").first() else { return nil }
        if let content = try? element.attr("content").trimmedNonEmpty { return content }
        return try? element.text().trimmedNonEmpty
    }

    // MARK: - Parsing primitives (pure, tested directly)

    /// Parses a price string into a Decimal, tolerating currency symbols, thousands
    /// separators, and surrounding text. Handles both `1,234.56` (US) and
    /// `1.234,56` (EU) by treating the LAST separator as the decimal point when it
    /// is followed by 1–2 digits.
    public static func parsePrice(_ raw: String) -> Decimal? { PriceParsing.parsePrice(raw) }


    /// Validates/uppercases a currency. Accepts a 3-letter ISO code; maps common
    /// symbols ($, £, €, ¥) to a code; returns nil for anything else.
    public static func normalizeCurrency(_ raw: String?) -> String? { PriceParsing.normalizeCurrency(raw)
    }

    /// Resolves a possibly-relative URL string against `baseURL`.
    public static func resolveURL(_ string: String, baseURL: URL?) -> URL? {
        if let absolute = URL(string: string), absolute.scheme != nil { return absolute }
        return URL(string: string, relativeTo: baseURL)?.absoluteURL
    }
}

extension String {
    /// The trimmed string, or nil if it's empty after trimming.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
