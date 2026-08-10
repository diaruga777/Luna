//
//  AmazonProductDetails.swift
//  LunaPriceMetadata
//

import Foundation

/// Reads the identifiers and the buy-box price out of an Amazon product page.
///
/// **Why this exists at all.** Amazon publishes no JSON-LD `Product`, no
/// `product:price:amount` meta tag, and no microdata. Everything a cross-retailer
/// comparison needs — the ISBN, the UPC/EAN, the "Item model number", the brand —
/// is plain text inside the product-details table, and the price is plain text
/// inside the buy box. So a page that any structured-data reader calls empty is
/// in fact the most completely identified page on the web, and Luna was walking
/// past it: an Amazon SOURCE save produced no keyed identifiers at all (so the
/// fan-out had nothing to verify anyone AGAINST), and an Amazon CANDIDATE parsed
/// with `price == nil` (so the lean profile could never price it). Amazon is the
/// single most important retailer in the feature and it was the one retailer that
/// could not participate in either direction.
///
/// **Why regex and not a DOM.** This module is Foundation-only by design: it is
/// the shared floor under both the SwiftSoup-backed ingest path and the lean
/// engine that has to fit inside the Safari appex. One implementation, both
/// tiers, no drift.
///
/// **Why label windows and not selectors.** Amazon ships at least four detail
/// layouts concurrently (the `prodDetTable` key/value table, the
/// `detailBullets` list, the newer "rich product information" cards, and the
/// product-overview grid), and which one a request gets depends on the device,
/// the category and the experiment bucket. Every one of them puts the label
/// immediately before the value, so this finds the LABEL and then reads the
/// first value-SHAPED run of text after it. Shape is what makes that safe: an
/// ISBN-13 window only ever yields thirteen digits.
public enum AmazonProductDetails {

    /// What an Amazon page turned out to state about the product's identity.
    public struct Identifiers: Equatable, Sendable {
        public var gtin: String?
        public var mpn: String?
        /// Amazon's ASIN. It is retailer-scoped, so it is a SKU rather than a
        /// global identifier or manufacturer part number.
        public var sku: String?
        public var brand: String?

        public init(
            gtin: String? = nil, mpn: String? = nil, sku: String? = nil, brand: String? = nil
        ) {
            self.gtin = gtin
            self.mpn = mpn
            self.sku = sku
            self.brand = brand
        }

        public var isEmpty: Bool { gtin == nil && mpn == nil && sku == nil && brand == nil }
    }

    /// Whether `host` is an Amazon storefront by SHAPE. The authoritative list
    /// is `AmazonStorefronts` (LunaURLClassification), which this module may not
    /// import; every caller that has the list should prefer it, and this is the
    /// fallback for the ones that do not.
    public static func isAmazonHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "amazon.com" || host.hasSuffix(".amazon.com")
            || host.range(of: #"(^|\.)amazon\.[a-z.]{2,6}$"#, options: .regularExpression) != nil
    }

    // MARK: - Identifiers

    /// The identifiers stated in `html`, plus anything derivable from `url`.
    ///
    /// The URL leg is not a nicety: for books, Amazon's ASIN IS the ISBN-10, so
    /// `/dp/0735211299` states the product's global identifier even on a page
    /// whose details table did not load. `GTINForms.isValidISBN10` is what keeps
    /// that from firing on an ordinary ASIN.
    public static func identifiers(inHTML html: String, url: URL?) -> Identifiers {
        // A product URL always states the ASIN even when Amazon lazy-loads or
        // omits every product-details module. Preserve it as retailer-scoped
        // identity; ordinary ASINs must never be promoted to GTIN/MPN.
        var found = Identifiers(sku: asin(in: url))
        let html = detailsRegions(in: html)

        for label in ["ISBN-13", "ISBN13"] {
            if let value = firstValue(after: label, in: html, matching: isbn13Shape) {
                found.gtin = GTINForms.digits(value)
                break
            }
        }
        if found.gtin == nil {
            for label in ["UPC", "EAN", "GTIN", "Global Trade Identification Number"] {
                if let value = firstValue(after: label, in: html, matching: barcodeShape) {
                    found.gtin = GTINForms.digits(value)
                    break
                }
            }
        }
        if found.gtin == nil {
            for label in ["ISBN-10", "ISBN10"] {
                if let value = firstValue(after: label, in: html, matching: isbn10Shape),
                   let digits = GTINForms.digits(value),
                   let isbn13 = GTINForms.isbn13(fromISBN10: digits) {
                    found.gtin = isbn13
                    break
                }
            }
        }
        for label in ["Item model number", "Part Number", "Model Number", "Manufacturer Part Number"] {
            if let value = firstValue(after: label, in: html, matching: modelShape) {
                found.mpn = value
                break
            }
        }
        // Brand only from the two labels that MEAN brand. "Publisher" is the
        // book analogue and is deliberately left out: a publisher is not what
        // another retailer prints as the brand, and a brand mismatch is a hard
        // refusal in two of the three verification tiers.
        for label in ["Brand", "Manufacturer"] {
            if let value = firstValue(after: label, in: html, matching: brandShape) {
                found.brand = value
                break
            }
        }

        // The ASIN leg, last: a details-table ISBN is a statement, an ASIN is an
        // inference, and the statement wins where both exist.
        if found.gtin == nil, let asin = asin(in: url),
           let isbn13 = GTINForms.isbn13(fromISBN10: asin) {
            found.gtin = isbn13
        }
        return found
    }

    /// The ASIN in an Amazon product URL (`/dp/<asin>`, `/gp/product/<asin>`).
    public static func asin(in url: URL?) -> String? {
        guard let path = url?.path,
              let range = path.range(
                of: "/(dp|gp/product)/[A-Z0-9]{10}", options: [.regularExpression])
        else { return nil }
        return String(path[range].suffix(10))
    }

    // MARK: - Descriptive metadata

    /// Amazon's visible product title, without the storefront/category chrome
    /// appended to the document title.
    public static func title(inHTML html: String) -> String? {
        guard let raw = captures(
            #"id\s*=\s*[\"']productTitle[\"'][^>]*>([\s\S]{1,2000}?)<"#, in: html
        ).first else { return nil }
        let title = strippedTags(raw)
        return title.isEmpty ? nil : title
    }

    /// Primary product artwork from Amazon's desktop and mobile image blocks.
    /// Amazon commonly omits `og:image`, but these blocks still carry a stable
    /// high-resolution media URL.
    public static func imageURL(inHTML html: String) -> URL? {
        guard let tag = firstMatch(
            #"<img\b[^>]*(?:id\s*=\s*[\"'](?:landingImage|main-image|imgBlkFront|ebooksImgBlkFront)[\"']|data-a-image-name\s*=\s*[\"']mainImage[\"']|data-fling-refmarker\s*=\s*[\"']detail_main_image_block[\"'])[^>]*>"#,
            in: html)
        else { return embeddedPrimaryImageURL(in: html) }

        for attribute in ["data-old-hires", "data-a-hires", "data-midres-replacement"] {
            if let raw = attributeValue(attribute, in: tag), let url = webURL(decodedHTML(raw)) {
                return url
            }
        }
        if let dynamic = attributeValue("data-a-dynamic-image", in: tag),
           let data = decodedHTML(dynamic).data(using: .utf8),
           let sizes = try? JSONSerialization.jsonObject(with: data) as? [String: [Int]],
           let raw = sizes.max(by: { imageArea($0.value) < imageArea($1.value) })?.key,
           let url = webURL(raw) {
            return url
        }
        for attribute in ["src", "data-src"] {
            if let raw = attributeValue(attribute, in: tag), let url = webURL(decodedHTML(raw)) {
                return url
            }
        }
        return embeddedPrimaryImageURL(in: html)
    }

    private static func embeddedPrimaryImageURL(in html: String) -> URL? {
        for pattern in [
            #"\"hiRes\"\s*:\s*\"(https?:\\?/\\?/[^\"]+)\""#,
            #"\"large\"\s*:\s*\"(https?:\\?/\\?/[^\"]+)\""#,
            #"\"mainUrl\"\s*:\s*\"(https?:\\?/\\?/[^\"]+)\""#,
        ] {
            guard let raw = captures(pattern, in: html).first else { continue }
            let unescaped = raw.replacingOccurrences(of: #"\/"#, with: "/")
            if let url = webURL(unescaped) { return url }
        }
        return nil
    }

    private static func attributeValue(_ name: String, in tag: String) -> String? {
        captures(#"\b\#(name)\s*=\s*[\"']([^\"']+)[\"']"#, in: tag).first
    }

    private static func imageArea(_ size: [Int]) -> Int {
        guard size.count >= 2 else { return 0 }
        return size[0] * size[1]
    }

    private static func decodedHTML(_ raw: String) -> String {
        raw.replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#34;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func webURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw),
              url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http"
        else { return nil }
        return url
    }

    // MARK: - Price

    /// Amazon's buy-box price and its currency, or nil.
    ///
    /// Anchored on the buy box rather than on "the first price on the page",
    /// because an Amazon page carries twenty-odd prices — other formats, other
    /// sellers, sponsored placements, the struck-through list price — and the
    /// first one in document order is routinely none of them.
    ///
    /// `currencyHint` is the storefront's transaction currency
    /// (`AmazonStorefronts`), used when the markup writes a bare symbol.
    public static func price(inHTML html: String, currencyHint: String?)
        -> (amount: Decimal, currency: String)? {
        for anchor in buyBoxAnchors {
            guard let anchorRange = html.range(of: anchor, options: [.literal]) else { continue }
            let windowEnd = html.index(
                anchorRange.upperBound, offsetBy: buyBoxWindow, limitedBy: html.endIndex)
                ?? html.endIndex
            let window = String(html[anchorRange.upperBound..<windowEnd])
            for raw in captures(#"a-offscreen[^>]*>([^<]{1,40})<"#, in: window) {
                guard let parsed = amount(from: raw, currencyHint: currencyHint) else { continue }
                return parsed
            }
            if let composed = composedPrice(in: window, currencyHint: currencyHint) {
                return composed
            }
        }
        return nil
    }

    /// The buy box's price when it is SPLIT across elements —
    /// `<span class="a-price-symbol">$</span><span class="a-price-whole">350…`
    /// `<span class="a-price-fraction">97</span>` — with the accessible
    /// `a-offscreen` copy served EMPTY, which is what the current desktop layout
    /// does on many pages. Without this leg, Amazon prices as nil on exactly the
    /// pages that are laid out most recently.
    static func composedPrice(in window: String, currencyHint: String?)
        -> (amount: Decimal, currency: String)? {
        guard let whole = captures(#"a-price-whole[^>]*>([0-9][0-9,.]{0,12})"#, in: window).first
        else { return nil }
        let fraction = captures(#"a-price-fraction[^>]*>([0-9]{1,2})"#, in: window).first ?? "00"
        let symbol = captures(#"a-price-symbol[^>]*>([^<]{1,6})"#, in: window).first ?? ""
        let digits = whole.filter { $0.isNumber || $0 == "," || $0 == "." }
        let cleaned = normalizedAmountString(digits)
            .components(separatedBy: ".")[0]
        guard let value = Decimal(string: "\(cleaned).\(fraction)"), value > 0 else { return nil }
        let letters = symbol.filter(\.isLetter).uppercased()
        let currency = letters.count == 3
            ? letters
            : (symbolCurrency(symbol) ?? currencyHint?.uppercased())
        guard let currency, currency.count == 3 else { return nil }
        return (value, currency)
    }

    /// Anchors in buy-box preference order. `apex-pricetopay-value` is the
    /// current one; the rest are layouts still served to some requests.
    static let buyBoxAnchors = [
        "apex-pricetopay-value",
        "priceToPay",
        "corePriceDisplay_desktop_feature_div",
        "corePrice_feature_div",
        "price_inside_buybox",
        "priceblock_ourprice",
        "priceblock_dealprice",
    ]

    /// How far past an anchor a price may sit. The offscreen span is the next
    /// element in every layout; this is slack, not a search.
    static let buyBoxWindow = 600

    static func amount(from raw: String, currencyHint: String?)
        -> (amount: Decimal, currency: String)? {
        let text = raw.replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let digits = text.filter { $0.isNumber || $0 == "." || $0 == "," }
        guard !digits.isEmpty,
              let value = Decimal(string: normalizedAmountString(digits)), value > 0
        else { return nil }
        let letters = text.filter(\.isLetter).uppercased()
        let currency: String?
        if letters.count == 3 {
            currency = letters
        } else if let hinted = currencyHint, hinted.count == 3 {
            currency = hinted.uppercased()
        } else {
            currency = symbolCurrency(text)
        }
        guard let currency else { return nil }
        return (value, currency)
    }

    static func symbolCurrency(_ text: String) -> String? {
        if text.contains("£") { return "GBP" }
        if text.contains("€") { return "EUR" }
        if text.contains("₹") { return "INR" }
        if text.contains("$") { return "USD" }
        return nil
    }

    static func normalizedAmountString(_ raw: String) -> String {
        guard let lastComma = raw.lastIndex(of: ","), let lastDot = raw.lastIndex(of: ".") else {
            if raw.contains(",") || raw.contains(".") {
                let separator: Character = raw.contains(",") ? "," : "."
                let parts = raw.split(separator: separator, omittingEmptySubsequences: false)
                    .map(String.init)
                if parts.count == 2, (1...2).contains(parts[1].count) {
                    return parts.joined(separator: ".")
                }
                return parts.joined()
            }
            return raw
        }
        return lastComma > lastDot
            ? raw.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            : raw.replacingOccurrences(of: ",", with: "")
    }

    // MARK: - Narrowing to the details

    /// The container ids Amazon's several detail layouts use, in no particular
    /// order — a page carries two or three of them and never all.
    static let detailContainerAnchors = [
        "productOverview_feature_div",
        "prodDetTable",
        "richProductInformation",
        "productDetails_techSpec_section",
        "productDetails_db_sections",
        "productDetails_detailBullets_sections",
        "detailBullets_feature_div",
        "detailBulletsWrapper_feature_div",
        "detail-bullets",
        "productDetails_feature_div",
    ]

    static let detailRegionWindow = 30_000
    static let maximumDetailRegionLength = 240_000

    /// The parts of the page that actually carry the details, concatenated.
    ///
    /// This is a precision fix before it is a speed one. Scanning the whole
    /// 2.5MB document for the word "Manufacturer" finds the WARRANTY PARAGRAPH
    /// first ("Manufacturer's warranty can be requested from customer service"),
    /// and the first plausible-looking run of text after it is not a brand.
    /// Narrowing to the detail containers removes that whole class of false
    /// positive — and, incidentally, takes the extraction from ~1.5s to a few
    /// milliseconds, which matters when it runs once per candidate page inside a
    /// 15s appex budget.
    ///
    /// A page carrying none of the containers falls back to the whole document,
    /// capped: an unrecognized layout should degrade to the old behaviour, not
    /// to nothing.
    static func detailsRegions(in html: String) -> String {
        var regions: [String] = []
        var total = 0
        for anchor in detailContainerAnchors {
            guard let range = html.range(of: anchor, options: [.literal]) else { continue }
            let end = html.index(
                range.upperBound, offsetBy: detailRegionWindow, limitedBy: html.endIndex)
                ?? html.endIndex
            let region = String(html[range.upperBound..<end])
            total += region.count
            regions.append(region)
            if total >= maximumDetailRegionLength { break }
        }
        guard regions.isEmpty else { return regions.joined(separator: "\n") }
        return String(html.prefix(maximumDetailRegionLength))
    }

    // MARK: - Label windows

    /// How far past a label a value may sit. Amazon's layouts put up to four
    /// wrapper elements (an icon span, two divs) between the two.
    static let labelWindow = 400

    /// The first value-shaped run of text after `label`, tags stripped.
    ///
    /// Every occurrence of the label is tried, because the same word appears in
    /// navigation and in warranty prose long before it appears as a details
    /// row — the shape test is what tells the real one apart, so the scan simply
    /// keeps going until a shape matches.
    static func firstValue(
        after label: String, in html: String, matching shape: (String) -> String?
    ) -> String? {
        var searchStart = html.startIndex
        var attempts = 0
        while let range = html.range(
            of: label, options: [.caseInsensitive], range: searchStart..<html.endIndex) {
            searchStart = range.upperBound
            attempts += 1
            guard attempts <= maximumLabelOccurrences else { return nil }
            // A label is a whole word: "Brand" must not fire inside "Branding".
            if range.upperBound < html.endIndex, html[range.upperBound].isLetter { continue }
            // …and it must be CONTENT, not markup. Amazon's product-overview
            // grid tags the row `class="po-brand"`, whose window's first text
            // node is the word "Brand" itself — so without this the brand of
            // every overview-grid page is the string "Brand".
            if isInsideTag(html, at: range.lowerBound) { continue }
            let windowEnd = html.index(
                range.upperBound, offsetBy: labelWindow, limitedBy: html.endIndex)
                ?? html.endIndex
            // The RAW window: a shape that wants plain text strips it itself,
            // and the brand shape needs the element boundaries to know where
            // the value ends.
            if let value = shape(String(html[range.upperBound..<windowEnd])) { return value }
        }
        return nil
    }

    static let maximumLabelOccurrences = 12

    /// Whether `index` sits inside a tag rather than in text content: walking
    /// back, the nearest angle bracket is an OPENING one.
    static func isInsideTag(_ html: String, at index: String.Index) -> Bool {
        let start = html.index(index, offsetBy: -tagLookBehind, limitedBy: html.startIndex)
            ?? html.startIndex
        for character in html[start..<index].reversed() {
            if character == "<" { return true }
            if character == ">" { return false }
        }
        return false
    }

    static let tagLookBehind = 400

    /// The first few non-empty text nodes in a fragment, in document order.
    static func firstTextNodes(in html: String, limit: Int) -> [String] {
        var nodes: [String] = []
        for raw in captures(#">([^<>]{1,80})<"#, in: html) {
            let text = raw
                .replacingOccurrences(of: "&nbsp;", with: " ")
                .replacingOccurrences(of: "&amp;", with: "&")
                .replacingOccurrences(of: "\u{00A0}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            nodes.append(text)
            if nodes.count >= limit { break }
        }
        return nodes
    }

    /// Tags out, entities that matter back in, whitespace collapsed. The value
    /// is always a short plain run, so nothing more is needed.
    static func strippedTags(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(
            of: "<[^>]*>", with: " ", options: [.regularExpression])
        return withoutTags
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: [.regularExpression])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Value shapes

    static func isbn13Shape(_ raw: String) -> String? {
        firstMatch(#"97[89][- ]?[0-9][- ]?[0-9]{2,7}[- ]?[0-9]{1,7}[- ]?[0-9]"#,
                   in: strippedTags(raw))
            .flatMap { GTINForms.digits($0)?.count == 13 ? $0 : nil }
    }

    static func isbn10Shape(_ raw: String) -> String? {
        firstMatch(#"(?<![0-9])[0-9][- ]?[0-9]{2,6}[- ]?[0-9]{1,6}[- ]?[0-9X](?![0-9])"#,
                   in: strippedTags(raw))
            .flatMap { candidate in
                guard let digits = GTINForms.digits(candidate), digits.count == 10,
                      GTINForms.isValidISBN10(digits) else { return nil }
                return digits
            }
    }

    static func barcodeShape(_ raw: String) -> String? {
        // A UPC row can list several barcodes; the first is the product's own.
        firstMatch(#"(?<![0-9])[0-9]{12,14}(?![0-9])"#, in: strippedTags(raw))
    }

    static func modelShape(_ raw: String) -> String? {
        guard let candidate = firstMatch(
            #"[A-Za-z0-9][A-Za-z0-9._/\-]{2,39}"#, in: strippedTags(raw))
        else { return nil }
        // A model number that is only letters is a leaked prose word.
        return candidate.contains(where: \.isNumber) ? candidate : nil
    }

    /// A brand is the VALUE NODE, not the next few words.
    ///
    /// Every detail layout puts the brand in its own element right after the
    /// label, so the honest reading is "the first non-empty text node", and
    /// taking a word count instead is what produced `Avery Publication date
    /// October` — the publisher plus the beginning of the next row.
    static func brandShape(_ text: String) -> String? {
        for node in firstTextNodes(in: text, limit: 3) {
            let candidate = node.trimmingCharacters(in: .whitespaces)
            guard candidate.count >= 2, candidate.count <= 40,
                  candidate.contains(where: \.isLetter),
                  !candidate.contains("’"), !candidate.contains("'"),
                  candidate.rangeOfCharacter(from: CharacterSet(charactersIn: ",;:‹›<>{}")) == nil
            else { continue }
            return candidate
        }
        return nil
    }

    // MARK: - Regex helpers

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text)
        else { return nil }
        return String(text[range])
    }

    static func captures(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { match in
                guard match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text)
                else { return nil }
                return String(text[range])
            }
    }
}
