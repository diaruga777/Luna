//
//  ProductMetadataExtractor.swift
//  ReaderKit
//

import Foundation
import ClipPriceMetadata
import SwiftSoup

/// The complete metadata for a page already classified as a `.product`. Price is
/// NON-OPTIONAL by construction: a `ProductMetadata` only exists once a real price
/// (with a known currency) was found, so a tracker can never be created without one
/// (the mandatory-price invariant lives in the type).
struct ProductMetadata: Equatable {
    let name: String
    /// The resolved price — always a real amount + currency.
    let price: ProductPrice
    let imageURL: URL?
    let brand: String?
    let productID: String?
}

/// A single site's price-extraction strategy. Pure, deterministic, currency-complete:
/// the currency MUST be resolved inside the rule (a declared code, else a host/TLD
/// map) — never a blind USD default. Register a new retailer by adding one conformer
/// to `ProductMetadataExtractor.hostRules`; the extractor itself never changes.
protocol ProductPriceRule {
    /// Whether this rule handles `host` (already lowercased, trailing dot stripped).
    func matches(host: String) -> Bool
    /// Extract `(amount, currency)` from this site's markup, or nil. `html` is the raw
    /// page; `document` is the same page parsed once (so a rule needn't re-parse).
    func price(html: String, document: Document, host: String) -> ProductPrice?
}

/// Stage-2 processing component: given a page ALREADY classified as a product (the
/// `Classifier` owns "is this a product?"; this component never re-decides that),
/// produce its complete metadata INCLUDING a mandatory price — from ONE price source.
///
/// One parse, one price: the per-host rule table is consulted first, then a generic
/// JSON-LD/OG/microdata/embedded-JSON fallback. There is no detect-then-refetch double
/// parse (the former "sometimes saves" root). The WKWebView render tier is reached
/// ONLY when `render != nil`; extensions pass `render: nil`, making the render tier
/// structurally unreachable there (the action-extension "spins forever" fix). It is
/// also hard-bounded wherever it runs.
struct ProductMetadataExtractor {

    /// Ordered, extensible per-host rules consulted before the generic fallback. First
    /// rule whose `matches(host:)` is true wins; its price is used if found.
    private let hostRules: [ProductPriceRule]

    /// Pulls the descriptive metadata (name/image/brand/id) from a parsed document —
    /// the existing pure detector, reused so there's one source of those fields.
    private let detector: ProductPageDetector

    init(
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
    func extract(
        url: URL, html: String, render: ((URL) async -> String?)? = nil
    ) async -> ProductMetadata? {
        // ONE parse of the static markup; ONE price source (host rule, else generic).
        if let metadata = metadata(url: url, html: html) {
            return metadata
        }
        // Render tier — main-app only, and only if static found no price.
        guard let render, let rendered = await render(url) else { return nil }
        return metadata(url: url, html: rendered)
    }

    /// The pure (no-network) static path: parse once, resolve the price via the host
    /// rule or the generic fallback, and assemble the metadata if a price was found.
    private func metadata(url: URL, html: String) -> ProductMetadata? {
        guard let document = try? SwiftSoup.parse(html, url.absoluteString) else { return nil }
        guard let price = resolvePrice(url: url, html: html, document: document) else { return nil }
        let fields = detector.metadataFields(document: document, baseURL: url)
        return ProductMetadata(
            name: fields.name, price: price, imageURL: fields.imageURL,
            brand: fields.brand, productID: fields.productID)
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

// MARK: - Per-host rules

/// Amazon: the buy-box price from Amazon's price model (`"priceAmount"` /
/// `"displayPrice"`), NOT the first `.a-offscreen` span (often a strikethrough list
/// price). Currency is a declared code, else the storefront TLD (so a bare `$` on
/// amazon.com.au resolves to AUD), never a blind USD default. Host matching uses the
/// complete current Amazon retail-storefront catalog, so `amazon.scam.com` can't
/// match and newly supported regional URLs stay consistent across the app.
struct AmazonPriceRule: ProductPriceRule {

    /// Every current Amazon retail storefront and its local transaction currency.
    /// The hostname registry is deliberately explicit (rather than accepting any
    /// `amazon.*` domain) to prevent lookalike hosts from becoming price sources.
    static let storefronts: [(host: String, currency: String)] = [
        ("amazon.com", "USD"), ("amazon.ca", "CAD"), ("amazon.com.mx", "MXN"),
        ("amazon.com.br", "BRL"), ("amazon.co.uk", "GBP"), ("amazon.de", "EUR"),
        ("amazon.fr", "EUR"), ("amazon.it", "EUR"), ("amazon.es", "EUR"),
        ("amazon.nl", "EUR"), ("amazon.se", "SEK"), ("amazon.pl", "PLN"),
        ("amazon.com.tr", "TRY"), ("amazon.com.be", "EUR"), ("amazon.ie", "EUR"),
        ("amazon.co.jp", "JPY"), ("amazon.in", "INR"), ("amazon.com.au", "AUD"),
        ("amazon.sg", "SGD"), ("amazon.ae", "AED"), ("amazon.sa", "SAR"),
        ("amazon.eg", "EGP"), ("amazon.co.za", "ZAR"),
    ]

    static let storefrontHosts = storefronts.map(\.host)

    func matches(host: String) -> Bool {
        Self.storefront(for: host) != nil
    }

    func price(html: String, document: Document, host: String) -> ProductPrice? {
        let currency = declaredCurrency(html)
            ?? Self.storefront(for: host)?.currency
        guard let currency else { return nil }   // no silent USD default

        // Buy-box first (Amazon's price model), then the buy-box-scoped offscreen span —
        // NOT the first `.a-offscreen` on the page (a strikethrough list price).
        let amount = Self.firstMatch(html, #""priceAmount"\s*:\s*([0-9]+(?:\.[0-9]+)?)"#)
            ?? Self.firstMatch(html, #""displayPrice"\s*:\s*"([^"]+)""#)
            ?? buyBoxOffscreenPrice(document)
        guard let raw = amount, let value = ProductPageDetector.parsePrice(raw), value >= 0 else {
            return nil
        }
        return ProductPrice(amount: value, currency: currency)
    }

    static func storefront(for host: String?) -> (host: String, currency: String)? {
        guard var normalized = host?.lowercased() else { return nil }
        if normalized.hasSuffix(".") { normalized.removeLast() }
        return storefronts.first { storefront in
            normalized == storefront.host || normalized.hasSuffix("." + storefront.host)
        }
    }

    /// A currency code explicitly declared in Amazon's embedded JSON.
    private func declaredCurrency(_ html: String) -> String? {
        for key in ["currencyCode", "priceCurrency"] {
            if let raw = Self.firstMatch(html, #""\#(key)"\s*:\s*"([A-Za-z]{3})""#),
               let code = ProductPageDetector.normalizeCurrency(raw) {
                return code
            }
        }
        return nil
    }

    /// The `.a-offscreen` price SCOPED to the core/buy-box price node, so a list-price
    /// strikethrough elsewhere on the page can't win. Falls back to the first
    /// `.a-offscreen` only if no scoped buy-box node exists.
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

    /// First capture group of `pattern` in `text`, or nil.
    private static func firstMatch(_ text: String, _ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges >= 2 else { return nil }
        return ns.substring(with: match.range(at: 1))
    }
}

/// Target: the current price from the `__NEXT_DATA__` app state
/// (`price.current_retail`). Currency is USD (Target is a US-only storefront), resolved
/// here rather than defaulted globally.
struct TargetPriceRule: ProductPriceRule {
    func matches(host: String) -> Bool {
        host == "target.com" || host.hasSuffix(".target.com")
    }

    func price(html: String, document: Document, host: String) -> ProductPrice? {
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
struct WalmartPriceRule: ProductPriceRule {
    func matches(host: String) -> Bool {
        host == "walmart.com" || host.hasSuffix(".walmart.com")
    }

    func price(html: String, document: Document, host: String) -> ProductPrice? {
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
enum NextDataPrice {

    /// The first numeric value found under any of `keys`, scanning the page's
    /// `__NEXT_DATA__` (and other `application/json`) blobs in a deterministic,
    /// depth-first, sorted-key order.
    static func amount(in document: Document, keys: [String]) -> Decimal? {
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
    static func currency(in document: Document) -> String? {
        for blob in jsonBlobs(in: document) {
            guard let data = blob.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let price = ProductPageDetector.firstPrice(in: parsed) { return price.currency }
        }
        return nil
    }

    /// `__NEXT_DATA__` first (richest), then other `application/json` scripts.
    private static func jsonBlobs(in document: Document) -> [String] {
        var blobs: [String] = []
        if let next = try? document.select("script#__NEXT_DATA__").first(),
           let json = try? next.html(), !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blobs.append(json)
        }
        if let scripts = try? document.select("script[type=application/json]") {
            for script in scripts {
                if let json = try? script.html(),
                   !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    blobs.append(json)
                }
            }
        }
        return blobs
    }

    /// Depth-first, sorted-key search for the first numeric value under any of `keys`
    /// (lowercased). A child object can itself BE the value's holder — e.g.
    /// `currentPrice: { price: 12.34 }` matches `currentPrice` by recursing into it and
    /// taking its own nested `price`. Sorted-key traversal keeps the result a pure
    /// function of the JSON content (Swift dictionary order is hash-seed randomized).
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
