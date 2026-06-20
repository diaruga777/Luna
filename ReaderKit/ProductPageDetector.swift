//
//  ProductPageDetector.swift
//  Clip
//

import Foundation
import SwiftSoup

/// A product (with a price) extracted from a saved web page. The presence of a
/// non-negative `priceAmount` and a non-empty `priceCurrency` is what turns a
/// save into a price tracker instead of an article, so both are required and
/// the type is only constructed when both are found.
struct ProductInfo: Equatable {
    /// Product display name (the page's product title).
    let name: String
    /// The numeric price. Always non-negative.
    let priceAmount: Decimal
    /// ISO 4217 currency code, uppercased (e.g. "USD", "GBP").
    let priceCurrency: String
    /// Best product image, if one was found.
    let imageURL: URL?
    /// Brand / manufacturer, if declared.
    let brand: String?
    /// A stable product identifier (GTIN/UPC/EAN/ISBN/MPN/SKU), if declared —
    /// the strongest signal for matching two store pages to the same product.
    let productID: String?
}

/// Pure detection of whether a saved page is a purchasable product with a price.
/// Given a URL + its HTML, returns `ProductInfo` when a price is found via any of
/// the supported signals, else nil. No I/O, no UIKit — fully fixture-testable.
///
/// Signals, in order of trust (first match for each field wins):
/// 1. JSON-LD `Product`/`Offer` (`offers.price` + `priceCurrency`) — recursing
///    `@graph` / arrays / nested offers, exactly like the article extractor's
///    JSON-LD walk.
/// 2. OpenGraph product meta (`product:price:amount` / `og:price:amount` +
///    matching currency).
/// 3. schema.org microdata (`itemprop="price"` + `itemprop="priceCurrency"`).
/// 4. Common bare price meta (`twitter:data1`, `product:price`) as a last resort.
struct ProductPageDetector {

    /// Returns the product info if `html` describes a priced product page.
    func detect(urlString: String, html: String) -> ProductInfo? {
        let baseURL = URL(string: urlString)
        guard let document = try? SwiftSoup.parse(html, urlString) else { return nil }
        return detect(document: document, baseURL: baseURL)
    }

    /// Detection over an already-parsed document (lets the article pipeline reuse
    /// a parse it already has).
    func detect(document: Document, baseURL: URL?) -> ProductInfo? {
        // 1) JSON-LD is the richest, most reliable source.
        if let info = productFromJSONLD(document: document, baseURL: baseURL) {
            return info
        }
        // 2/3/4) fall back to meta tags + microdata, assembling fields piecemeal.
        guard let (amount, currency) = priceFromMetaOrMicrodata(document: document) else {
            return nil
        }
        let name = productName(document: document, baseURL: baseURL)
        return ProductInfo(
            name: name,
            priceAmount: amount,
            priceCurrency: currency,
            imageURL: productImage(document: document, baseURL: baseURL),
            brand: brand(document: document),
            productID: microdataProductID(document: document)
        )
    }

    // MARK: - JSON-LD

    private func productFromJSONLD(document: Document, baseURL: URL?) -> ProductInfo? {
        guard let scripts = try? document.select("script[type=application/ld+json]") else {
            return nil
        }
        for script in scripts {
            guard let data = script.data().data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let node = firstProductNode(in: parsed),
               let info = Self.productInfo(fromProductNode: node, document: document, baseURL: baseURL) {
                return info
            }
        }
        return nil
    }

    /// Finds the first JSON-LD node whose `@type` is (or includes) `Product`,
    /// recursing through `@graph` arrays and nested objects.
    private func firstProductNode(in object: Any) -> [String: Any]? {
        if let dictionary = object as? [String: Any] {
            if Self.typeContains(dictionary["@type"], "Product") { return dictionary }
            for value in dictionary.values {
                if let found = firstProductNode(in: value) { return found }
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

    /// Pure assembly of `ProductInfo` from a parsed JSON-LD `Product` node.
    /// Internal (not private) so it's directly unit-testable on a dictionary.
    static func productInfo(
        fromProductNode node: [String: Any], document: Document?, baseURL: URL?
    ) -> ProductInfo? {
        guard let offer = firstOffer(in: node),
              let (amount, currency) = price(fromOffer: offer) else { return nil }

        let name = (node["name"] as? String)?.trimmedNonEmpty
            ?? document.flatMap { ProductPageDetector().productName(document: $0, baseURL: baseURL) }
            ?? "Product"

        let image = imageURL(from: node["image"], baseURL: baseURL)
        let brand = brandName(from: node["brand"])
        let productID = self.productID(from: node, offer: offer)

        return ProductInfo(
            name: name, priceAmount: amount, priceCurrency: currency,
            imageURL: image, brand: brand, productID: productID
        )
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

    // MARK: - Meta / microdata

    private func priceFromMetaOrMicrodata(document: Document) -> (Decimal, String)? {
        // OpenGraph / product meta.
        let amountKeys = ["product:price:amount", "og:price:amount", "product:price"]
        let currencyKeys = ["product:price:currency", "og:price:currency", "product:currency"]
        if let raw = metaContent(document, names: amountKeys),
           let amount = Self.parsePrice(raw), amount >= 0 {
            let currency = Self.normalizeCurrency(metaContent(document, names: currencyKeys)) ?? "USD"
            return (amount, currency)
        }
        // schema.org microdata.
        if let raw = itempropValue(document, "price"),
           let amount = Self.parsePrice(raw), amount >= 0 {
            let currency = Self.normalizeCurrency(itempropValue(document, "priceCurrency")) ?? "USD"
            return (amount, currency)
        }
        return nil
    }

    private func microdataProductID(document: Document) -> String? {
        for prop in ["gtin13", "gtin12", "gtin14", "gtin8", "gtin", "sku", "mpn", "productID"] {
            if let value = itempropValue(document, prop)?.trimmedNonEmpty { return value }
        }
        return nil
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
        return baseURL?.host?.replacingOccurrences(of: "www.", with: "") ?? "Product"
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
    static func parsePrice(_ raw: String) -> Decimal? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Keep digits and separators only.
        let allowed = Set("0123456789.,")
        let filtered = String(trimmed.filter { allowed.contains($0) })
        guard !filtered.isEmpty, filtered.contains(where: \.isNumber) else { return nil }

        let lastDot = filtered.lastIndex(of: ".")
        let lastComma = filtered.lastIndex(of: ",")
        var normalized = filtered

        switch (lastDot, lastComma) {
        case let (dot?, comma?):
            // Both present: the later one is the decimal separator.
            if dot > comma {
                normalized = filtered.replacingOccurrences(of: ",", with: "")
            } else {
                normalized = filtered.replacingOccurrences(of: ".", with: "")
                    .replacingOccurrences(of: ",", with: ".")
            }
        case (_?, nil):
            normalized = filtered   // dot already the decimal point
        case let (nil, comma?):
            // Only a comma: decimal separator if followed by 1–2 digits, else a
            // thousands grouping (e.g. "1,234").
            let afterComma = filtered.distance(from: comma, to: filtered.endIndex) - 1
            if afterComma == 1 || afterComma == 2 {
                normalized = filtered.replacingOccurrences(of: ",", with: ".")
            } else {
                normalized = filtered.replacingOccurrences(of: ",", with: "")
            }
        case (nil, nil):
            break
        }
        return Decimal(string: normalized)
    }

    /// Validates/uppercases a currency. Accepts a 3-letter ISO code; maps common
    /// symbols ($, £, €, ¥) to a code; returns nil for anything else.
    static func normalizeCurrency(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let upper = raw.uppercased()
        if upper.count == 3, upper.allSatisfy(\.isLetter) { return upper }
        switch raw {
        case "$": return "USD"
        case "£": return "GBP"
        case "€": return "EUR"
        case "¥": return "JPY"
        default: return nil
        }
    }

    /// Resolves a possibly-relative URL string against `baseURL`.
    static func resolveURL(_ string: String, baseURL: URL?) -> URL? {
        if let absolute = URL(string: string), absolute.scheme != nil { return absolute }
        return URL(string: string, relativeTo: baseURL)?.absoluteURL
    }
}

private extension String {
    /// The trimmed string, or nil if it's empty after trimming.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
