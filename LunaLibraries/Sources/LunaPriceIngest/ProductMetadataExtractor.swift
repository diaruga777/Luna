//
//  ProductMetadataExtractor.swift
//  ReaderKit
//

import Foundation
import LunaHTMLClassification
import LunaModels
import LunaPriceMetadata
import LunaURLClassification
import SwiftSoup

/// The complete metadata for a page already classified as a `.product`. Price
/// is non-optional by construction: a `ProductMetadata` only exists once a
/// real price with a known currency was found, so a tracker can never be
/// created without one. The mandatory-price invariant lives in the type.
public struct ProductMetadata: Equatable {
    public let name: String
    /// The resolved price: always a real amount plus currency.
    public let price: ProductPrice
    public let imageURL: URL?
    public let brand: String?
    public let productID: String?
    /// The keyed identifiers the page declared (`ProductIdentifiers`): what a
    /// cross-seller comparison matches on, since only a GTIN travels between
    /// retailers.
    public let identifiers: ProductIdentifiers
    /// Seller listings discovered on an aggregate shopping page. Empty for ordinary
    /// product pages.
    public let sellers: [ProductSellerInfo]

    public init(
        name: String, price: ProductPrice, imageURL: URL?, brand: String?, productID: String?,
        identifiers: ProductIdentifiers = ProductIdentifiers(),
        sellers: [ProductSellerInfo] = []
    ) {
        self.name = name
        self.price = price
        self.imageURL = imageURL
        self.brand = brand
        self.productID = productID
        self.identifiers = identifiers
        self.sellers = sellers
    }
}

/// A single site's price-extraction strategy. Pure, deterministic,
/// currency-complete: the rule must resolve the currency itself (a declared
/// code, else a host/TLD map), never a blind USD default. Register a new
/// retailer by adding one conformer to `ProductMetadataExtractor.hostRules`;
/// the extractor itself never changes.
public protocol ProductPriceRule {
    /// Whether this rule handles `host` (already lowercased, trailing dot stripped).
    func matches(host: String) -> Bool
    /// Extract `(amount, currency)` from this site's markup, or nil. `html` is the raw
    /// page; `document` is the same page parsed once (so a rule needn't re-parse).
    func price(html: String, document: Document, host: String) -> ProductPrice?
}

/// Stage-2 processing component: given a page already classified as a
/// product (the `Classifier` owns "is this a product?"; this component never
/// re-decides that), produces its complete metadata, including a mandatory
/// price, from one price source.
///
/// One parse, one price source per extraction: no detect-then-refetch double
/// parse. The per-host rule table is consulted first, then a generic
/// JSON-LD/OG/microdata/embedded-JSON fallback. The WKWebView render tier is
/// reached only when `render != nil`. Extensions pass `render: nil`, so the
/// render tier is structurally unreachable there — it can never spin up a
/// `WKWebView` in the memory-limited extension host. It is also
/// hard-bounded wherever it runs.
public struct ProductMetadataExtractor {

    /// Ordered, extensible per-host rules consulted before the generic fallback. First
    /// rule whose `matches(host:)` is true wins; its price is used if found.
    private let hostRules: [ProductPriceRule]

    /// Pulls the descriptive metadata (name/image/brand/id) from a parsed document —
    /// the existing pure detector, reused so there's one source of those fields.
    private let detector: ProductPageDetector

    public init(
        hostRules: [ProductPriceRule] = [AmazonPriceRule(), TargetPriceRule(), WalmartPriceRule()],
        detector: ProductPageDetector = ProductPageDetector()
    ) {
        self.hostRules = hostRules
        self.detector = detector
    }

    /// Extract the product metadata for `url` from `html`. Returns nil when no real
    /// price can be resolved (a product-looking page with no resolvable price yields
    /// nil so the caller falls back to an article — never a price-less tracker).
    ///
    /// - `render`: the injected bounded WebView render tier (`(URL) async -> String?`).
    ///   Pass `nil` in app extensions and tests — the render tier is then structurally
    ///   unreachable, so a JS-only price resolves to nil (→ article) instead of spinning
    ///   up a `WKWebView` in the memory-limited extension host.
    public func extract(
        url: URL, html: String, render: ((URL) async -> String?)? = nil
    ) async -> ProductMetadata? {
        // One parse of the static markup; one price source (host rule, else generic).
        if let metadata = metadata(url: url, html: html) {
            SaveDiagnostics.record(
                "product: static markup yielded \(metadata.price.amount) "
                    + "\(metadata.price.currency)",
                category: "price")
            return metadata
        }
        // Render tier — main-app only, and only if static found no price.
        guard let render else {
            SaveDiagnostics.record(
                "product: no price in \(html.count)ch of static markup, no render tier here",
                category: "price")
            return nil
        }
        guard let rendered = await render(url) else {
            SaveDiagnostics.record(
                "product: no price in \(html.count)ch of static markup, render tier "
                    + "returned nothing",
                category: "price")
            return nil
        }
        let renderedMetadata = metadata(url: url, html: rendered)
        SaveDiagnostics.record(
            "product: render tier returned \(rendered.count)ch → "
                + (renderedMetadata.map { "\($0.price.amount) \($0.price.currency)" }
                    ?? "still no price"),
            category: "price")
        return renderedMetadata
    }

    /// The pure (no-network) static path: parse once, resolve the price via the host
    /// rule or the generic fallback, and assemble the metadata if a price was found.
    private func metadata(url: URL, html: String) -> ProductMetadata? {
        guard let document = try? SwiftSoup.parse(html, url.absoluteString) else { return nil }
        if let googleShopping = GoogleShoppingProductParser.metadata(
            url: url, html: html, document: document) {
            return googleShopping
        }
        guard let price = resolvePrice(url: url, html: html, document: document) else { return nil }
        let fields = detector.metadataFields(document: document, baseURL: url)
        let amazon = AmazonStorefronts.storefront(for: url.host) == nil
            ? nil
            : AmazonProductDetails.identifiers(inHTML: html, url: url)
        let identifiers = enrichedIdentifiers(fields.identifiers, amazon: amazon)
        return ProductMetadata(
            name: amazon == nil
                ? fields.name
                : (AmazonProductDetails.title(inHTML: html) ?? fields.name),
            price: price,
            imageURL: AmazonStorefronts.storefront(for: url.host) == nil
                ? fields.imageURL
                : (AmazonProductDetails.imageURL(inHTML: html) ?? fields.imageURL),
            brand: fields.brand ?? amazon?.brand,
            productID: fields.productID ?? amazon?.sku,
            identifiers: identifiers)
    }

    /// Fills identifier gaps from retailer markup that publishes no structured
    /// data at all.
    ///
    /// Amazon is the whole of it today, and it is not a small case: it
    /// publishes no JSON-LD `Product`. Without this fallback, a save from
    /// the most important retailer in the feature would carry no keyed
    /// identifiers, leaving its alternative-seller fan-out nothing to verify
    /// any candidate against. The ISBN/UPC/EAN, the "Item model number", and
    /// the brand are plain text in the product-details table, and for books
    /// the ASIN in the URL is the ISBN-10.
    ///
    /// The reader is `AmazonProductDetails` in LunaPriceMetadata, the same
    /// code the lean comparison engine runs, so the two tiers cannot
    /// disagree about what an Amazon page says. Structured extraction still
    /// wins: this only fills what came back empty.
    private func enrichedIdentifiers(
        _ identifiers: ProductIdentifiers, amazon details: AmazonProductDetails.Identifiers?
    ) -> ProductIdentifiers {
        guard let details else { return identifiers }
        guard !details.isEmpty else { return identifiers }
        return identifiers.merging(ProductIdentifiers(
            gtin: details.gtin, mpn: details.mpn, sku: details.sku, brand: details.brand))
    }

    /// The single price source: the first matching host rule, else the generic
    /// JSON-LD/OG/microdata/embedded-JSON fallback. Pure.
    private func resolvePrice(url: URL, html: String, document: Document) -> ProductPrice? {
        if var host = url.host?.lowercased() {
            if host.hasSuffix(".") { host.removeLast() }
            if let rule = hostRules.first(where: { $0.matches(host: host) }),
               let price = rule.price(html: html, document: document, host: host) {
                return price
            }
        }
        if let parsed = ProductMetadataParsing.firstJSONLDProduct(in: html),
           let amount = parsed.price, let currency = parsed.currency, !currency.isEmpty {
            return ProductPrice(amount: amount, currency: currency)
        }
        return detector.genericStructuredPrice(document: document, baseURL: url)
    }
}

// MARK: - Google Shopping aggregate pages

/// Google Shopping search pages are aggregate listings, not sellers. When a user
/// saves one, track the seller product pages Google lists instead of google.com.
enum GoogleShoppingProductParser {
    static func metadata(url: URL, html: String, document: Document) -> ProductMetadata? {
        guard GoogleShoppingURL.isProductPage(url) else { return nil }
        let sellers = sellerListings(document: document, baseURL: url)
        guard !sellers.isEmpty,
              let best = sellers.min(by: { $0.price.amount < $1.price.amount })
        else { return nil }
        return ProductMetadata(
            name: productName(document: document, fallbackURL: url),
            price: best.price,
            imageURL: nil,
            brand: nil,
            productID: nil,
            sellers: sellers)
    }

    private static func sellerListings(document: Document, baseURL: URL) -> [ProductSellerInfo] {
        guard let links = try? document.select("a[href]") else { return [] }
        var listings: [ProductSellerInfo] = []
        var seen = Set<String>()
        for link in links.array() {
            guard let href = try? link.attr("href"),
                  let sellerURL = sellerURL(from: href, baseURL: baseURL),
                  let price = priceNear(link, sellerURL: sellerURL)
            else { continue }
            let key = canonicalKey(sellerURL)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            listings.append(ProductSellerInfo(url: sellerURL, price: price))
        }
        return listings
    }

    private static func sellerURL(from href: String, baseURL: URL) -> URL? {
        guard !href.isEmpty else { return nil }
        let resolved: URL?
        if href.hasPrefix("http://") || href.hasPrefix("https://") {
            resolved = URL(string: href)
        } else {
            resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL
        }
        guard let candidate = resolved else { return nil }
        let unwrapped = unwrapGoogleRedirect(candidate) ?? candidate
        guard let scheme = unwrapped.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              !isGoogleOwnedHost(unwrapped.host)
        else { return nil }
        return cleanedSellerURL(unwrapped)
    }

    private static func unwrapGoogleRedirect(_ url: URL) -> URL? {
        guard isGoogleOwnedHost(url.host),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        for key in ["url", "q", "adurl"] {
            if let value = components.queryItems?.first(where: { $0.name == key })?.value,
               let target = URL(string: value) {
                return target
            }
        }
        return nil
    }

    private static func isGoogleOwnedHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "google.com"
            || host.hasSuffix(".google.com")
            || host == "g.co"
            || host.hasSuffix(".g.co")
            || host == "googleusercontent.com"
            || host.hasSuffix(".googleusercontent.com")
            || host == "gstatic.com"
            || host.hasSuffix(".gstatic.com")
    }

    private static func priceNear(_ element: Element, sellerURL: URL) -> ProductPrice? {
        var current: Element? = element
        for _ in 0..<6 {
            if let text = try? current?.text(), let price = price(in: text, sellerURL: sellerURL) {
                return price
            }
            current = current?.parent()
        }
        return nil
    }

    private static func price(in text: String, sellerURL: URL) -> ProductPrice? {
        let pattern = #"(?i)(?:A\$|AU\$|US\$|\$|£|€|¥)\s*[0-9][0-9.,]*"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        let raw = String(text[range])
        guard let amount = ProductPageDetector.parsePrice(raw),
              let currency = currency(in: raw, sellerURL: sellerURL)
        else { return nil }
        return ProductPrice(amount: amount, currency: currency)
    }

    private static func currency(in raw: String, sellerURL: URL) -> String? {
        let upper = raw.uppercased()
        if upper.contains("A$") || upper.contains("AU$") { return "AUD" }
        if upper.contains("US$") { return "USD" }
        if raw.contains("£") { return "GBP" }
        if raw.contains("€") { return "EUR" }
        if raw.contains("¥") { return "JPY" }
        if let host = sellerURL.host?.lowercased(),
           host == "au" || host.hasSuffix(".au") || host.hasSuffix(".com.au") {
            return "AUD"
        }
        return ProductPageDetector.normalizeCurrency("$")
    }

    private static func productName(document: Document, fallbackURL: URL) -> String {
        let selectors = [
            #"meta[property="og:title"]"#,
            #"meta[name="title"]"#,
        ]
        for selector in selectors {
            if let meta = try? document.select(selector).first(),
               let content = try? meta.attr("content"),
               !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return cleanTitle(content)
            }
        }
        if let title = try? document.title(),
           !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return cleanTitle(title)
        }
        let query = URLComponents(url: fallbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value
        return query?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? query!
            : "Product"
    }

    private static func cleanTitle(_ title: String) -> String {
        title
            .replacingOccurrences(of: " - Google Shopping", with: "")
            .replacingOccurrences(of: " - Google Search", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Dedup key: host + path only. Google appends per-link click-tracking
    /// query params (`srsltid`, `region_id`, store ids, …), so the same
    /// retailer's product page is often listed under two different query
    /// strings. Ignoring the query entirely when deduping collapses those
    /// to one seller.
    private static func canonicalKey(_ url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        let path = HostMatching.normalizedPath(url.path.lowercased())
        return host + path
    }

    private static func cleanedSellerURL(_ url: URL) -> URL? {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        let queryItems = components?.queryItems?.filter { item in
            let name = item.name.lowercased()
            // Drop tracking params Google attaches to seller links so the stored
            // tracker URL stays clean across refreshes.
            return !name.hasPrefix("utm_") && name != "srsltid" && name != "gclid"
        }
        components?.queryItems = queryItems?.isEmpty == true ? nil : queryItems
        return components?.url
    }
}

// MARK: - Per-host rules

/// Amazon: the buy-box price from Amazon's price model (`"priceAmount"` /
/// `"displayPrice"`), not the first `.a-offscreen` span (often a
/// strikethrough list price). Currency is a declared code, else the
/// storefront TLD (so a bare `$` on amazon.com.au resolves to AUD), never a
/// blind USD default. Host matching uses the complete current Amazon
/// retail-storefront catalog, so `amazon.scam.com` cannot match, and newly
/// supported regional URLs stay consistent across the app.
public struct AmazonPriceRule: ProductPriceRule {
    public init() {}

    /// The storefront registry is classification data shared with the
    /// deterministic shop table (`AmazonStorefronts`, LunaURLClassification);
    /// these aliases keep this rule's own naming.
    public static let storefronts = AmazonStorefronts.storefronts

    public static let storefrontHosts = AmazonStorefronts.hosts

    public func matches(host: String) -> Bool {
        Self.storefront(for: host) != nil
    }

    public func price(html: String, document: Document, host: String) -> ProductPrice? {
        let currency = declaredCurrency(html)
            ?? Self.storefront(for: host)?.currency
        guard let currency else { return nil }   // no silent USD default

        // Buy-box first (Amazon's price model), then the buy-box-scoped
        // offscreen span, not the first `.a-offscreen` on the page (a
        // strikethrough list price).
        let amount = RegexCapture.first(in: html, pattern: #""priceAmount"\s*:\s*([0-9]+(?:\.[0-9]+)?)"#)
            ?? RegexCapture.first(in: html, pattern: #""displayPrice"\s*:\s*"([^"]+)""#)
            ?? buyBoxOffscreenPrice(document)
        guard let raw = amount, let value = ProductPageDetector.parsePrice(raw), value >= 0 else {
            return nil
        }
        return ProductPrice(amount: value, currency: currency)
    }

    public static func storefront(for host: String?) -> (host: String, currency: String)? {
        AmazonStorefronts.storefront(for: host)
    }

    /// A currency code explicitly declared in Amazon's embedded JSON.
    private func declaredCurrency(_ html: String) -> String? {
        for key in ["currencyCode", "priceCurrency"] {
            if let raw = RegexCapture.first(in: html, pattern: #""\#(key)"\s*:\s*"([A-Za-z]{3})""#),
               let code = ProductPageDetector.normalizeCurrency(raw) {
                return code
            }
        }
        return nil
    }

    /// The `.a-offscreen` price scoped to the core/buy-box price node, so a
    /// list-price strikethrough elsewhere on the page cannot win. Falls back
    /// to the first `.a-offscreen` only if no scoped buy-box node exists.
    private func buyBoxOffscreenPrice(_ document: Document) -> String? {
        let buyBoxSelectors = [
            "#corePriceDisplay_desktop_feature_div", "#corePrice_feature_div",
            "#corePriceDisplay_mobile_feature_div", "#buybox", "#price_inside_buybox",
        ]
        for selector in buyBoxSelectors {
            if let node = try? document.select(selector).first(),
               let span = try? node.select(".a-offscreen").first(),
               let text = try? span.text(), text.contains(where: \.isNumber) {
                return text
            }
        }
        return nil
    }

}

/// Target: the current price from the `__NEXT_DATA__` app state
/// (`price.current_retail`). Currency is USD (Target is a US-only storefront), resolved
/// here rather than defaulted globally.
public struct TargetPriceRule: ProductPriceRule {
    public init() {}
    public func matches(host: String) -> Bool {
        host == "target.com" || host.hasSuffix(".target.com")
    }

    public func price(html: String, document: Document, host: String) -> ProductPrice? {
        // Target renders the price client-side but ships it in `__NEXT_DATA__` as
        // `price.current_retail` (a bare number). Recover it from the embedded JSON.
        guard let amount = NextDataPrice.amount(
            in: document, keys: ["current_retail", "currentRetail", "formatted_current_price"])
        else { return nil }
        let currency = NextDataPrice.currency(in: document) ?? "USD"
        return ProductPrice(amount: amount, currency: currency)
    }
}

/// Walmart: the current price from the `__NEXT_DATA__` app state
/// (`priceInfo.currentPrice.price`). Currency is USD (Walmart US), resolved here.
public struct WalmartPriceRule: ProductPriceRule {
    public init() {}
    public func matches(host: String) -> Bool {
        host == "walmart.com" || host.hasSuffix(".walmart.com")
    }

    public func price(html: String, document: Document, host: String) -> ProductPrice? {
        guard let amount = NextDataPrice.amount(
            in: document, keys: ["currentPrice", "price", "current_retail"])
        else { return nil }
        let currency = NextDataPrice.currency(in: document) ?? "USD"
        return ProductPrice(amount: amount, currency: currency)
    }
}

/// Shared `__NEXT_DATA__` price recovery for the Next.js retailers (Target/Walmart).
/// Reuses `ProductPageDetector.firstPrice` where a price node carries its own currency,
/// and a keyed-scan fallback for the bare-number shapes those sites use.
public enum NextDataPrice {

    /// The first numeric value found under any of `keys`, scanning the page's
    /// `__NEXT_DATA__` (and other `application/json`) blobs in a deterministic,
    /// depth-first, sorted-key order.
    public static func amount(in document: Document, keys: [String]) -> Decimal? {
        let wanted = Set(keys.map { $0.lowercased() })
        for blob in jsonBlobs(in: document) {
            guard let data = blob.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data),
                  let value = numericValue(in: parsed, forKeys: wanted) else { continue }
            return value
        }
        return nil
    }

    /// The first currency code declared anywhere in the page's JSON blobs (a price node
    /// found by `ProductPageDetector.firstPrice` carries it), else nil.
    public static func currency(in document: Document) -> String? {
        for blob in jsonBlobs(in: document) {
            guard let data = blob.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let price = ProductPageDetector.firstPrice(in: parsed) { return price.currency }
        }
        return nil
    }

    /// `__NEXT_DATA__` first (richest), then other `application/json` scripts.
    private static func jsonBlobs(in document: Document) -> [String] {
        EmbeddedJSONBlobs.nextDataAndJSONScripts(in: document)
    }

    /// Depth-first, sorted-key search for the first numeric value under any
    /// of `keys` (lowercased). A child object can itself be the value's
    /// holder: `currentPrice: { price: 12.34 }` matches `currentPrice` by
    /// recursing into it and taking its own nested `price`. Sorted-key
    /// traversal keeps the result a pure function of the JSON content,
    /// since Swift dictionary order is hash-seed randomized.
    private static func numericValue(in object: Any, forKeys keys: Set<String>) -> Decimal? {
        if let dictionary = object as? [String: Any] {
            for key in dictionary.keys.sorted() where keys.contains(key.lowercased()) {
                if let amount = decimal(dictionary[key]) { return amount }
                // Nested holder (e.g. currentPrice.price): take any numeric leaf under it.
                if let value = dictionary[key], let nested = firstNumericLeaf(in: value) {
                    return nested
                }
            }
            for key in dictionary.keys.sorted() {
                if let value = dictionary[key], let found = numericValue(in: value, forKeys: keys) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = numericValue(in: value, forKeys: keys) { return found }
            }
        }
        return nil
    }

    /// The first numeric leaf reachable from `object` in sorted-key order (used when a
    /// matched key holds a small price object like `{ price: 12.34, ... }`).
    private static func firstNumericLeaf(in object: Any) -> Decimal? {
        if let amount = decimal(object) { return amount }
        if let dictionary = object as? [String: Any] {
            for key in dictionary.keys.sorted() {
                if let value = dictionary[key], let found = firstNumericLeaf(in: value) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = firstNumericLeaf(in: value) { return found }
            }
        }
        return nil
    }

    private static func decimal(_ value: Any?) -> Decimal? {
        if let string = value as? String { return ProductPageDetector.parsePrice(string) }
        if let number = value as? NSNumber {
            // Reject bools masquerading as NSNumber (true/false are NSNumber-backed).
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return number.decimalValue
        }
        return nil
    }
}
