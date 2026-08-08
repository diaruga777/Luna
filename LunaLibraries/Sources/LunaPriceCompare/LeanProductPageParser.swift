//
//  LeanProductPageParser.swift
//  LunaPriceCompare
//

import Foundation
import LunaModels

/// What one candidate seller page turned out to be: enough to decide "is this
/// the same product, and what does it cost here?" and nothing more.
///
/// Two producers fill this in — `LeanProductPageParser` (regex only, the profile
/// the Safari appex and every extension use) and, in the full profile, an
/// injected rich resolver that routes the page through the shared ingest
/// pipeline. The fan-out is written against the type, not against either
/// producer, which is what lets the same orchestration run in both places.
public struct ParsedProductPage: Equatable, Sendable {
    public let url: URL
    public let name: String
    public let price: Decimal?
    public let currency: String?
    public let imageURL: URL?
    public let identifiers: ProductIdentifiers

    public init(
        url: URL, name: String, price: Decimal?, currency: String?,
        imageURL: URL? = nil, identifiers: ProductIdentifiers = ProductIdentifiers()
    ) {
        self.url = url
        self.name = name
        self.price = price
        self.currency = currency
        self.imageURL = imageURL
        self.identifiers = identifiers
    }

    /// Whether this page is usable as a comparison result: a real positive
    /// price with a known currency.
    public var hasUsablePrice: Bool {
        guard let price, let currency else { return false }
        return price > 0 && currency.count == 3
    }
}

/// Regex-only extraction of the few fields a price comparison needs, from raw
/// HTML. No SwiftSoup, no WKWebView, no DOM — this module has to link into the
/// Safari appex, and a real HTML parser does not fit there.
///
/// It reads strictly less than `ProductPageDetector`: structured data
/// (JSON-LD, then OpenGraph/microdata) and nothing heuristic. That is the right
/// trade for a candidate page — a seller whose price only exists after
/// client-side rendering is simply skipped, and the next candidate is tried.
public enum LeanProductPageParser {

    // MARK: - Product page

    /// The product this page describes, or nil when it declares no product at
    /// all. A non-nil result may still have no price (`hasUsablePrice`).
    public static func parse(html: String, url: URL) -> ParsedProductPage? {
        let jsonLD = jsonLDProduct(in: html)
        let name = jsonLD?.name
            ?? metaContent(html, names: ["og:title", "twitter:title"])
            ?? htmlTitle(html)
        guard let name, !name.isEmpty else { return nil }

        let metaPrice = metaContent(
            html, names: ["product:price:amount", "og:price:amount", "product:price"])
            .flatMap { Decimal(string: normalizedAmount($0)) }
        let metaCurrency = metaContent(
            html, names: ["product:price:currency", "og:price:currency", "product:currency"])
            .flatMap(normalizedCurrency)

        let microdataPrice = itempropContent(html, "price")
            .flatMap { Decimal(string: normalizedAmount($0)) }
        let microdataCurrency = itempropContent(html, "priceCurrency").flatMap(normalizedCurrency)

        let identifiers = (jsonLD?.identifiers ?? ProductIdentifiers())
            .merging(microdataIdentifiers(html))

        let image = jsonLD?.imageURL
            ?? metaContent(html, names: ["og:image", "twitter:image", "product:image"])
        return ParsedProductPage(
            url: url,
            name: name,
            price: jsonLD?.price ?? metaPrice ?? microdataPrice,
            currency: jsonLD?.currency ?? metaCurrency ?? microdataCurrency,
            imageURL: image.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL },
            identifiers: identifiers)
    }

    // MARK: - Search results

    /// The most plausible product-page links in a seller's own search-results
    /// HTML, in document order, at most `limit`.
    ///
    /// Deliberately shape-based rather than site-specific: a per-retailer result
    /// selector for 200-odd sellers is a maintenance surface nobody can keep
    /// green, and a wrong link costs one skipped candidate, not a wrong price —
    /// the match verifier still has to accept the page it lands on.
    public static func productLinks(
        inSearchHTML html: String, baseURL: URL, limit: Int
    ) -> [URL] {
        guard limit > 0 else { return [] }
        let searchDomain = ProductIdentityMatching.registrableDomain(baseURL.host ?? "")
        var strict: [URL] = []
        var loose: [URL] = []
        var seen: Set<String> = []

        for href in hrefs(in: html) {
            guard let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  let scheme = resolved.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = resolved.host,
                  ProductIdentityMatching.registrableDomain(host) == searchDomain
            else { continue }
            let canonical = canonicalURL(resolved)
            guard seen.insert(canonical.absoluteString).inserted else { continue }
            if LeanProductURLRules.looksLikeProduct(canonical) {
                strict.append(canonical)
            } else if !LeanProductURLRules.isMultiProductListing(canonical),
                      looksLikeProductBySegment(canonical) {
                loose.append(canonical)
            }
        }
        return Array((strict + loose).prefix(limit))
    }

    /// Product URL shapes the shared rule table does not cover, because they
    /// carry a slug rather than a numeric id (`/p/sony-wh-1000xm5`,
    /// `/ip/…`, Target's `/-/A-12345`). Only consulted after the shared
    /// patterns miss, and only for links that are not themselves listings.
    static let productPathNeedles = [
        "/dp/", "/gp/product/", "/p/", "/ip/", "/itm/", "/product/", "/products/",
        "/prd/", "/pd/", "/-/a-", "/buy/", "/shop/product",
    ]

    static func looksLikeProductBySegment(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        guard path.count > 1 else { return false }
        return productPathNeedles.contains { path.contains($0) }
    }

    /// Drops the fragment and the tracking-parameter families that make the same
    /// page look like several, so one seller page is fetched at most once.
    static func canonicalURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.fragment = nil
        let host = (components.host ?? "").lowercased()
        components.queryItems = components.queryItems?.filter { item in
            let lower = item.name.lowercased()
            if ["srsltid", "gclid", "ref", "sid", "clickid"].contains(lower) { return false }
            if lower.hasPrefix("utm_") { return false }
            if lower == "tag", host.contains("amazon.") { return false }
            return true
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url ?? url
    }

    // MARK: - JSON-LD

    struct JSONLDProduct {
        let name: String?
        let price: Decimal?
        let currency: String?
        let imageURL: String?
        let identifiers: ProductIdentifiers
    }

    /// The first JSON-LD `Product` node on the page. Same regex-scan-then-
    /// `JSONSerialization` approach as `ProductMetadataParsing.firstJSONLDProduct`,
    /// widened to also read the keyed identifiers and the image, and to walk
    /// child objects in SORTED KEY order so a `@graph` with several products
    /// always resolves to the same one (dictionary order is hash-seeded per
    /// process).
    static func jsonLDProduct(in html: String) -> JSONLDProduct? {
        for block in jsonLDBlocks(in: html) {
            guard let data = block.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let node = firstProductNode(in: object) else { continue }
            let offer = firstOffer(in: node) ?? [:]
            let brand = brandName(from: node["brand"])
            return JSONLDProduct(
                name: (node["name"] as? String)?.trimmedOrNil,
                price: decimal(offer["price"] ?? offer["lowPrice"]
                    ?? (offer["priceSpecification"] as? [String: Any])?["price"]),
                currency: normalizedCurrency(
                    (offer["priceCurrency"] as? String)
                        ?? ((offer["priceSpecification"] as? [String: Any])?["priceCurrency"] as? String)),
                imageURL: imageString(from: node["image"]),
                identifiers: ProductIdentifiers(
                    gtin: stringValue(
                        in: [node, offer],
                        keys: ["gtin13", "gtin12", "gtin14", "gtin8", "gtin", "isbn"]),
                    mpn: stringValue(in: [node, offer], keys: ["mpn"]),
                    sku: stringValue(in: [node, offer], keys: ["sku"]),
                    brand: brand))
        }
        return nil
    }

    private static func jsonLDBlocks(in html: String) -> [String] {
        let pattern = #"<script[^>]+type=[\"']application/ld\+json[\"'][^>]*>([\s\S]*?)</script>"#
        return captures(pattern, in: html, options: [.caseInsensitive])
    }

    private static func firstProductNode(in object: Any) -> [String: Any]? {
        if let dictionary = object as? [String: Any] {
            if typeContains(dictionary["@type"], "Product") { return dictionary }
            for key in dictionary.keys.sorted() {
                if let value = dictionary[key], let found = firstProductNode(in: value) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = firstProductNode(in: value) { return found }
            }
        }
        return nil
    }

    private static func typeContains(_ value: Any?, _ target: String) -> Bool {
        if let string = value as? String {
            return string.caseInsensitiveCompare(target) == .orderedSame
        }
        if let array = value as? [Any] {
            return array.contains { ($0 as? String)?.caseInsensitiveCompare(target) == .orderedSame }
        }
        return false
    }

    private static func firstOffer(in node: [String: Any]) -> [String: Any]? {
        guard let offers = node["offers"] else { return node["price"] != nil ? node : nil }
        if let dictionary = offers as? [String: Any] {
            if let nested = dictionary["offers"], let inner = firstOfferValue(nested) { return inner }
            return dictionary
        }
        return firstOfferValue(offers)
    }

    private static func firstOfferValue(_ value: Any) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        if let array = value as? [Any] { return array.compactMap { $0 as? [String: Any] }.first }
        return nil
    }

    private static func stringValue(in sources: [[String: Any]], keys: [String]) -> String? {
        for source in sources {
            for key in keys {
                if let value = (source[key] as? String)?.trimmedOrNil { return value }
                if let number = source[key] as? NSNumber { return number.stringValue }
            }
        }
        return nil
    }

    private static func brandName(from value: Any?) -> String? {
        if let string = value as? String { return string.trimmedOrNil }
        if let dictionary = value as? [String: Any] {
            return (dictionary["name"] as? String)?.trimmedOrNil
        }
        return nil
    }

    private static func imageString(from value: Any?) -> String? {
        if let string = value as? String { return string.trimmedOrNil }
        if let array = value as? [Any] {
            if let first = array.compactMap({ $0 as? String }).first { return first.trimmedOrNil }
            return (array.compactMap { $0 as? [String: Any] }.first?["url"] as? String)?.trimmedOrNil
        }
        if let dictionary = value as? [String: Any] {
            return (dictionary["url"] as? String)?.trimmedOrNil
        }
        return nil
    }

    private static func decimal(_ value: Any?) -> Decimal? {
        switch value {
        case let number as NSNumber: return Decimal(string: number.stringValue)
        case let string as String: return Decimal(string: normalizedAmount(string))
        default: return nil
        }
    }

    // MARK: - Meta / microdata

    static func metaContent(_ html: String, names: [String]) -> String? {
        for name in names {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            for attribute in ["property", "name"] {
                let pattern = "<meta[^>]+\(attribute)=[\"']\(escaped)[\"'][^>]*>"
                for tag in matches(pattern, in: html, options: [.caseInsensitive]) {
                    if let content = attributeValue("content", in: tag)?.trimmedOrNil {
                        return content
                    }
                }
                // `content` may precede the identifying attribute in the tag.
                let reversed = "<meta[^>]*\(attribute)=[\"']\(escaped)[\"'][^>]*>"
                for tag in matches(reversed, in: html, options: [.caseInsensitive]) {
                    if let content = attributeValue("content", in: tag)?.trimmedOrNil {
                        return content
                    }
                }
            }
        }
        return nil
    }

    static func itempropContent(_ html: String, _ prop: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: prop)
        let pattern = "<[a-zA-Z]+[^>]*itemprop=[\"']\(escaped)[\"'][^>]*>"
        for tag in matches(pattern, in: html, options: [.caseInsensitive]) {
            if let content = attributeValue("content", in: tag)?.trimmedOrNil { return content }
        }
        return nil
    }

    static func microdataIdentifiers(_ html: String) -> ProductIdentifiers {
        func first(_ props: [String]) -> String? {
            for prop in props {
                if let value = itempropContent(html, prop) { return value }
            }
            return nil
        }
        return ProductIdentifiers(
            gtin: first(["gtin13", "gtin12", "gtin14", "gtin8", "gtin", "isbn"]),
            mpn: first(["mpn"]),
            sku: first(["sku"]),
            brand: first(["brand"]) ?? metaContent(html, names: ["product:brand", "og:brand"]))
    }

    static func htmlTitle(_ html: String) -> String? {
        captures("<title[^>]*>([\\s\\S]*?)</title>", in: html, options: [.caseInsensitive])
            .first?
            .trimmedOrNil
    }

    // MARK: - Small primitives

    static func hrefs(in html: String) -> [String] {
        captures("href\\s*=\\s*[\"']([^\"'\\s]+)[\"']", in: html, options: [.caseInsensitive])
    }

    static func attributeValue(_ name: String, in tag: String) -> String? {
        captures("\(name)\\s*=\\s*[\"']([^\"']*)[\"']", in: tag, options: [.caseInsensitive]).first
    }

    /// Strips currency symbols, thousands separators and whitespace so
    /// `"$1,299.00"` parses. A comma-decimal amount (`"1.299,00"`) is converted
    /// to a dot decimal.
    static func normalizedAmount(_ raw: String) -> String {
        let stripped = raw.filter { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }
        guard let lastComma = stripped.lastIndex(of: ","),
              let lastDot = stripped.lastIndex(of: ".") else {
            if stripped.contains(","), !stripped.contains(".") {
                // Ambiguous: a single comma with 1–2 trailing digits is a decimal
                // separator; anything else is a thousands separator.
                let parts = stripped.components(separatedBy: ",")
                if parts.count == 2, (1...2).contains(parts[1].count) {
                    return parts.joined(separator: ".")
                }
                return stripped.replacingOccurrences(of: ",", with: "")
            }
            return stripped
        }
        return lastComma > lastDot
            ? stripped.replacingOccurrences(of: ".", with: "")
                .replacingOccurrences(of: ",", with: ".")
            : stripped.replacingOccurrences(of: ",", with: "")
    }

    static func normalizedCurrency(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let letters = raw.uppercased().filter { $0.isLetter }
        if letters.count == 3 { return letters }
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "$": return "USD"
        case "£": return "GBP"
        case "€": return "EUR"
        default: return nil
        }
    }

    private static func matches(
        _ pattern: String, in text: String, options: NSRegularExpression.Options
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private static func captures(
        _ pattern: String, in text: String, options: NSRegularExpression.Options
    ) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { match in
                guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
                else { return nil }
                return String(text[range])
            }
    }
}

extension String {
    var trimmedOrNil: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
