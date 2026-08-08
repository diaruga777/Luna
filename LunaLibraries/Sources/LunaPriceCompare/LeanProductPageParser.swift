//
//  LeanProductPageParser.swift
//  LunaPriceCompare
//

import Foundation
import LunaModels
import LunaPriceMetadata
import LunaURLClassification

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
    public static func parse(html: String, url: URL, currencyHint: String? = nil)
        -> ParsedProductPage? {
        let jsonLD = jsonLDProduct(in: html)
        let name = (jsonLD?.name
            ?? metaContent(html, names: ["og:title", "twitter:title"])
            ?? htmlTitle(html))
            .map(ProductTitleHygiene.cleaned)
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

        var identifiers = (jsonLD?.identifiers ?? ProductIdentifiers())
            .merging(microdataIdentifiers(html))
        var price = jsonLD?.price ?? metaPrice ?? microdataPrice
        var currency = jsonLD?.currency ?? metaCurrency ?? microdataCurrency

        // Amazon publishes no structured data at all — no JSON-LD, no price
        // meta, no microdata — so everything above resolves to nil on the single
        // most important retailer in the feature. Its identifiers and its buy
        // box are plain text, and `AmazonProductDetails` is the one reader of
        // them, shared with the SwiftSoup-backed ingest path so the two tiers
        // cannot disagree about what an Amazon page says.
        if AmazonProductDetails.isAmazonHost(url.host) {
            let details = AmazonProductDetails.identifiers(inHTML: html, url: url)
            identifiers = identifiers.merging(ProductIdentifiers(
                gtin: details.gtin, mpn: details.mpn, brand: details.brand))
            if price == nil || currency == nil,
               let amazon = AmazonProductDetails.price(
                inHTML: html, currencyHint: AmazonStorefronts.storefront(for: url.host)?.currency) {
                price = amazon.amount
                currency = amazon.currency
            }
        }

        // Last: the app-state JSON a client-rendered PDP ships its price in.
        // Target's `price.current_retail` and Walmart's
        // `priceInfo.currentPrice.price` are the shapes `TargetPriceRule` /
        // `WalmartPriceRule` already read in the SwiftSoup tier — the same JSON,
        // the same keys, found with a regex instead of a DOM, because without it
        // a whole class of modern retailer parses with `price == nil` and can
        // never be a comparison result on the lean path.
        if price == nil || currency == nil,
           let embedded = embeddedJSONPrice(in: html, currencyHint: currencyHint) {
            price = embedded.amount
            currency = embedded.currency
        }

        let image = jsonLD?.imageURL
            ?? metaContent(html, names: ["og:image", "twitter:image", "product:image"])
        return ParsedProductPage(
            url: url,
            name: name,
            price: price,
            currency: currency,
            imageURL: image.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL },
            identifiers: identifiers)
    }

    // MARK: - Search results

    /// The most plausible product-page links in a seller's own search-results
    /// HTML, in document order, at most `limit`.
    ///
    /// Three things about this are the difference between a fan-out that finds
    /// sellers and one that finds none, and all three were measured against real
    /// search pages rather than reasoned about:
    ///
    /// 1. **It reads the whole document, not just `<a href="…">`.** eBay's search
    ///    page writes its hrefs UNQUOTED (`href=https://…`) and Walmart's, when
    ///    they exist, sit inside embedded JSON as `"canonicalUrl":"https:\/\/…"`.
    ///    A quoted-attribute regex found 0 of eBay's 99 product URLs.
    /// 2. **It knows each retailer's own product-path shape**
    ///    (`LeanProductURLRules.retailerRules`). Every one of Barnes & Noble's 79
    ///    products is under `/w/`, which no shared pattern matches; the ONE link
    ///    the shared patterns did find was a Nook e-reader sample.
    /// 3. **It refuses the retailer's own non-product furniture** — help, cart,
    ///    store locator, `nook.*` — which a whole-document scan otherwise picks
    ///    up by the dozen before the first real product.
    ///
    /// Links are ranked retailer-shape first, then the shared strict patterns,
    /// then the generic slug shapes, and within each tier they stay in document
    /// order — a search page puts its best result first, and nothing here should
    /// second-guess that.
    ///
    /// `preferring` — the searched product's identifier in every digit form it
    /// might be written in — outranks all three tiers. A retailer that puts the
    /// id in the link (`…?ean=9780735211292`, Amazon's `/dp/<isbn10>`) has
    /// already told us which of its fifty results is the right one, and taking
    /// its word is both cheaper and more accurate than fetching three
    /// neighbouring editions to find out.
    public static func productLinks(
        inSearchHTML html: String, baseURL: URL, limit: Int, preferring: [String] = []
    ) -> [URL] {
        guard limit > 0 else { return [] }
        let searchDomain = ProductIdentityMatching.registrableDomain(baseURL.host ?? "")
        let retailerRule = LeanProductURLRules.retailerRule(forHost: baseURL.host ?? "")
        let preferred = preferring.filter { $0.count >= 8 }
        var identified: [URL] = []
        var retailerShaped: [URL] = []
        var strict: [URL] = []
        var loose: [URL] = []
        var seen: Set<String> = []

        for href in candidateURLStrings(in: html) {
            // The best tier is already full and nothing weaker can displace it.
            if identified.count >= limit { break }
            guard let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  let scheme = resolved.scheme?.lowercased(), scheme == "http" || scheme == "https",
                  let host = resolved.host,
                  LeanProductURLRules.domainIsInScope(
                    ProductIdentityMatching.registrableDomain(host),
                    forSearchDomain: searchDomain),
                  !LeanProductURLRules.isExcludedNonProductURL(resolved)
            else { continue }
            let canonical = canonicalURL(resolved)
            guard seen.insert(canonical.absoluteString).inserted else { continue }
            let path = canonical.path
            if let retailerRule, matchesAny(retailerRule.reject, path) { continue }
            let isRetailerShaped = retailerRule.map { matchesAny($0.accept, path) } ?? false
            let isProductShaped = isRetailerShaped
                || LeanProductURLRules.looksLikeProduct(canonical)
                || (!LeanProductURLRules.isMultiProductListing(canonical)
                    && looksLikeProductBySegment(canonical))
            guard isProductShaped else { continue }
            let text = canonical.absoluteString
            if preferred.contains(where: { text.contains($0) }) {
                identified.append(canonical)
            } else if isRetailerShaped {
                retailerShaped.append(canonical)
            } else if LeanProductURLRules.looksLikeProduct(canonical) {
                strict.append(canonical)
            } else {
                loose.append(canonical)
            }
        }
        return Array((identified + retailerShaped + strict + loose).prefix(limit))
    }

    static func matchesAny(_ patterns: [String], _ path: String) -> Bool {
        patterns.contains { path.range(of: $0, options: .regularExpression) != nil }
    }

    /// Every URL-shaped string in the document, in document order: quoted and
    /// unquoted `href` values, plus any absolute `http(s)` URL anywhere in the
    /// text (embedded JSON is where half of a modern search page's product links
    /// actually live).
    ///
    /// JSON escaping is undone first — `https:\/\/…` and `/` are how a URL
    /// looks inside a `<script>` payload, and neither survives a naive scan.
    static func candidateURLStrings(in html: String) -> [String] {
        let unescaped = html
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u002F", with: "/")
            .replacingOccurrences(of: "\\u002f", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
        let pattern =
            #"href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'<>]+))|(https?://[^\s"'<>\\)\]}]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        var found: [String] = []
        let range = NSRange(unescaped.startIndex..., in: unescaped)
        regex.enumerateMatches(in: unescaped, range: range) { match, _, stop in
            guard let match else { return }
            for group in 1...4 where match.range(at: group).location != NSNotFound {
                guard let captured = Range(match.range(at: group), in: unescaped) else { continue }
                let value = trimmedURLString(String(unescaped[captured]))
                if !value.isEmpty { found.append(value) }
                break
            }
            if found.count >= maximumScannedURLs { stop.pointee = true }
        }
        return found
    }

    /// A whole-document scan on a 3MB search page can otherwise walk tens of
    /// thousands of asset URLs; the products are never past this many.
    static let maximumScannedURLs = 8000

    /// Trailing punctuation a URL picks up from the prose or JSON around it.
    static func trimmedURLString(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = value.last, ".,;:!\"'".contains(last) { value.removeLast() }
        return value
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

    /// Tracking parameter NAMES dropped outright, and the PREFIXES whose whole
    /// family is dropped. Everything else survives, because a search-result link
    /// can legitimately need a parameter to resolve (`bestbuy.com/site/…?skuId=`
    /// is a different product without it).
    static let trackingParameterNames: Set<String> = [
        "srsltid", "gclid", "ref", "ref_", "sid", "clickid", "irgwc", "sourceid",
        "psc", "qid", "sr", "dib", "dib_tag", "crid", "sprefix", "th", "keywords",
        "linkcode", "content-id", "smid", "hash", "itmmeta", "itmprp", "epid",
        "amdata", "campid", "toolid", "customid", "athbdg", "athcpid", "veh",
        "wmlspartner", "sharedid", "affinityoverride", "adsredirect", "cmpid",
        "camp", "creative", "creativeasin", "ascsubtag", "tduid", "clickref",
    ]
    static let trackingParameterPrefixes = ["utm_", "pd_rd_", "pf_rd_", "_trk", "mk", "gad_"]

    /// Drops the fragment and the tracking-parameter families that make the same
    /// page look like several, so one seller page is fetched at most once.
    ///
    /// Amazon additionally collapses to `/dp/<ASIN>`: a search page emits the
    /// same ASIN under a dozen slugs and a `/ref=` crumb apiece, and without
    /// this a candidate's three link slots are three copies of one product.
    static func canonicalURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return url }
        components.fragment = nil
        let host = (components.host ?? "").lowercased()
        components.queryItems = components.queryItems?.filter { item in
            let lower = item.name.lowercased()
            if trackingParameterNames.contains(lower) { return false }
            if trackingParameterPrefixes.contains(where: { lower.hasPrefix($0) }) { return false }
            if lower == "tag", host.contains("amazon.") { return false }
            return true
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        if host.contains("amazon."),
           let asin = components.path.range(
            of: "/(dp|gp/product)/[A-Z0-9]{10}", options: .regularExpression) {
            components.path = "/dp/" + String(components.path[asin].suffix(10))
            components.queryItems = nil
        } else if let crumb = components.path.range(of: "/ref=") {
            components.path = String(components.path[..<crumb.lowerBound])
        }
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

    // MARK: - Embedded app-state JSON

    /// Price keys the Next.js retailers use, in the order
    /// `TargetPriceRule`/`WalmartPriceRule` try them.
    static let embeddedPriceKeys: Set<String> = [
        "current_retail", "currentretail", "formatted_current_price",
        "currentprice", "price", "linepriceamount",
    ]

    /// The price a client-rendered PDP shipped in its app state, if any.
    ///
    /// `currencyHint` is the storefront's own currency, taken from the
    /// directory's region — these blobs usually state a bare number, and
    /// guessing the currency from a `.com` would be worse than being told.
    static func embeddedJSONPrice(in html: String, currencyHint: String?)
        -> (amount: Decimal, currency: String)? {
        for blob in embeddedJSONBlobs(in: html) {
            guard let data = blob.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data)
            else { continue }
            guard let amount = numericValue(in: parsed, forKeys: embeddedPriceKeys, depth: 0),
                  amount > 0
            else { continue }
            let currency = declaredCurrency(in: parsed, depth: 0)
                ?? currencyHint.flatMap(normalizedCurrency)
            guard let currency else { continue }
            return (amount, currency)
        }
        return nil
    }

    /// `__NEXT_DATA__` first (richest), then any other `application/json`
    /// script — the same two sources `EmbeddedJSONBlobs` reads with SwiftSoup.
    static func embeddedJSONBlobs(in html: String) -> [String] {
        var blobs = captures(
            #"<script[^>]*id=[\"']__NEXT_DATA__[\"'][^>]*>([\s\S]*?)</script>"#,
            in: html, options: [.caseInsensitive])
        blobs.append(contentsOf: captures(
            #"<script[^>]*type=[\"']application/json[\"'][^>]*>([\s\S]*?)</script>"#,
            in: html, options: [.caseInsensitive]))
        return blobs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Depth-first, SORTED-KEY search for the first numeric value under any of
    /// `keys`. Sorted rather than natural order because Swift's dictionary
    /// iteration is hash-seeded per process, and a price that changes between
    /// launches is worse than no price.
    static func numericValue(in object: Any, forKeys keys: Set<String>, depth: Int) -> Decimal? {
        guard depth < maximumJSONDepth else { return nil }
        if let dictionary = object as? [String: Any] {
            for key in dictionary.keys.sorted() where keys.contains(key.lowercased()) {
                if let amount = decimal(dictionary[key]) { return amount }
                if let value = dictionary[key],
                   let nested = firstNumericLeaf(in: value, depth: depth + 1) {
                    return nested
                }
            }
            for key in dictionary.keys.sorted() {
                if let value = dictionary[key],
                   let found = numericValue(in: value, forKeys: keys, depth: depth + 1) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = numericValue(in: value, forKeys: keys, depth: depth + 1) {
                    return found
                }
            }
        }
        return nil
    }

    static func firstNumericLeaf(in object: Any, depth: Int) -> Decimal? {
        guard depth < maximumJSONDepth else { return nil }
        if let amount = decimal(object) { return amount }
        if let dictionary = object as? [String: Any] {
            for key in dictionary.keys.sorted() {
                if let value = dictionary[key],
                   let found = firstNumericLeaf(in: value, depth: depth + 1) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = firstNumericLeaf(in: value, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    static func declaredCurrency(in object: Any, depth: Int) -> String? {
        guard depth < maximumJSONDepth else { return nil }
        if let dictionary = object as? [String: Any] {
            for key in dictionary.keys.sorted()
            where ["pricecurrency", "currencycode", "currency"].contains(key.lowercased()) {
                if let code = normalizedCurrency(dictionary[key] as? String) { return code }
            }
            for key in dictionary.keys.sorted() {
                if let value = dictionary[key],
                   let found = declaredCurrency(in: value, depth: depth + 1) { return found }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = declaredCurrency(in: value, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    /// App-state blobs are deep and occasionally cyclic-looking after
    /// serialization; this bounds the walk.
    static let maximumJSONDepth = 24

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
