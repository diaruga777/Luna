//
//  ProductSnapshot.swift
//  LunaPriceCompare
//

import Foundation
import LunaModels

/// A UTC calendar day written `yyyy-MM-dd`, whose LEXICOGRAPHIC order is its
/// chronological order — which is why sorting, pruning and dedup all compare
/// the text rather than parse a date.
///
/// It encodes and decodes as that bare string, so a snapshot record or index
/// written before this type existed reads back unchanged.
public struct UTCDay: Codable, Comparable, Hashable, Sendable, CustomStringConvertible {
    /// The persisted form, read at a JSON or SQL boundary and nowhere else.
    public let text: String

    private init(text: String) { self.text = text }

    /// The UTC day `date` falls on.
    public init(_ date: Date) { self.text = Self.formatter.string(from: date) }

    /// nil for anything that is not already a zero-padded `yyyy-MM-dd` day —
    /// the padding is what makes the text order the date order.
    public init?(parsing text: String) {
        guard let date = Self.formatter.date(from: text),
              Self.formatter.string(from: date) == text
        else { return nil }
        self.text = text
    }

    /// This day's UTC midnight.
    public var startOfDayUTC: Date? { Self.formatter.date(from: text) }

    public var description: String { text }

    public static func < (lhs: UTCDay, rhs: UTCDay) -> Bool { lhs.text < rhs.text }

    public init(from decoder: Decoder) throws {
        text = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

/// One product observation: what the product is, what it cost, and when.
///
/// A snapshot is written for EVERY product page any Luna process observes and
/// for every alternative-seller result a fan-out returns — unconditionally, with
/// no setting anywhere able to suppress it (`claudedocs/price-tracking.md`'s
/// "Product snapshots"). It is never a save: no save row, no refresh, no
/// alert. Its whole purpose is that a price tracker created LATER can be born
/// with a history instead of a single point.
///
/// Deliberately light — identifiers, a price with its currency, a date, and the
/// page it came from. No HTML, no images beyond a URL string.
///
/// It lives in `LunaPriceCompare` because that is the one kind module the Safari
/// appexes link: the extension, the app, and the share/action extensions all
/// write through the SAME `ProductSnapshotStore` rather than through a
/// hand-copied twin.
public struct ProductSnapshot: Codable, Equatable, Sendable {
    /// Product display name at capture time.
    public var name: String
    /// The price, as a decimal string (never a `Double` — precision matters
    /// for later comparisons).
    public var price: String
    /// ISO 4217 currency code, uppercased.
    public var currency: String
    /// The locale the price was read in, when the observing process knows it
    /// (`en_AU` for a page read on an Australian storefront). Diagnostic
    /// context for the currency, never a matching key — matching is by
    /// identifier, and the CURRENCY is what decides comparability.
    public var locale: String?
    /// The canonical page URL (tracking params stripped) at capture time.
    public var url: String
    /// `url`'s host, stored alongside for cheap grouping/matching.
    public var host: String
    /// UTC calendar day the capture happened on — the same bucketing
    /// `PriceDaySnapshot` uses for tracker history.
    public var day: UTCDay
    /// Full capture instant (ISO 8601).
    public var capturedAt: String
    /// GTIN/UPC/EAN/ISBN family identifier, if declared.
    public var gtin: String?
    /// Manufacturer part number, if declared.
    public var mpn: String?
    /// Retailer SKU, if declared.
    public var sku: String?
    /// A generic `productID` the page declared (schema.org `productID`),
    /// distinct from the more specific keyed identifiers above.
    public var productID: String?
    /// A retailer-assigned item id read from the URL or `product:retailer_item_id`
    /// (Amazon ASIN, eBay item id, Target TCIN, …) — unique within one retailer
    /// family, never across them.
    public var retailerItemID: String?
    /// Brand / manufacturer, if declared.
    public var brand: String?
    /// Product artwork declared by the rendered page. Especially important for
    /// Amazon, whose product image is commonly absent from Open Graph metadata.
    public var imageURL: String?

    public init(
        name: String, price: String, currency: String, locale: String? = nil,
        url: String, host: String, day: UTCDay, capturedAt: String,
        gtin: String? = nil, mpn: String? = nil, sku: String? = nil,
        productID: String? = nil, retailerItemID: String? = nil,
        brand: String? = nil, imageURL: String? = nil
    ) {
        self.name = name
        self.price = price
        self.currency = currency
        self.locale = locale
        self.url = url
        self.host = host
        self.day = day
        self.capturedAt = capturedAt
        self.gtin = gtin
        self.mpn = mpn
        self.sku = sku
        self.productID = productID
        self.retailerItemID = retailerItemID
        self.brand = brand
        self.imageURL = imageURL
    }

    /// `price` parsed back to a `Decimal`, or nil if the persisted string is malformed.
    public var priceAmount: Decimal? { Decimal(string: price) }

    /// `capturedAt` as an instant, falling back to `day`'s UTC midnight.
    public var capturedInstant: Date? {
        ISO8601DateFormatter().date(from: capturedAt) ?? day.startOfDayUTC
    }

    /// The index keys this snapshot is filed under — one per identifier it
    /// actually declares, plus its own canonical URL. A lookup that produces
    /// ANY of these finds it.
    public var indexKeys: [String] {
        var keys: [String] = []
        keys.append(contentsOf: ProductSnapshotKeys.gtinKeys(gtin))
        keys.append(contentsOf: ProductSnapshotKeys.retailerKeys(retailerItemID, host: host))
        keys.append(contentsOf: ProductSnapshotKeys.mpnKeys(mpn))
        keys.append(contentsOf: ProductSnapshotKeys.skuKeys(sku, host: host))
        keys.append(ProductSnapshotKeys.urlKey(url))
        keys.append(contentsOf: ProductSnapshotKeys.nameKeys(name, brand: brand, host: host))
        return orderedUnique(keys)
    }
}

/// The identifier → index-key derivation, shared by the WRITE side (a snapshot
/// files itself under every identifier it declares) and the READ side (a
/// candidate product asks for every identifier it carries).
///
/// Each key is namespaced by the identifier's SCOPE, because the scopes are not
/// interchangeable: a GTIN is global, a retailer item id belongs to one retailer
/// family, an SKU to one host. Baking the scope into the key is what lets the
/// lookup be a dictionary hit instead of a scan plus a per-tier predicate.
public enum ProductSnapshotKeys {

    /// Globally-unique identifier: matches across every host.
    public static func gtinKeys(_ raw: String?) -> [String] {
        guard let normalized = ProductIdentityMatching
            .normalizedGTIN(ProductIdentityMatching.normalizedID(raw))
        else { return [] }
        return ["g:\(normalized)"]
    }

    /// Retailer-assigned item id (ASIN, TCIN, …): scoped to one retailer family.
    public static func retailerKeys(_ raw: String?, host: String?) -> [String] {
        guard let normalized = ProductIdentityMatching.normalizedID(raw),
              let host, !host.isEmpty
        else { return [] }
        return ["r:\(ProductIdentityMatching.registrableDomain(host)):\(normalized)"]
    }

    /// Manufacturer part number: manufacturer-scoped (a compatible brand is
    /// still checked downstream).
    public static func mpnKeys(_ raw: String?) -> [String] {
        guard let normalized = ProductIdentityMatching.normalizedID(raw) else { return [] }
        return ["m:\(normalized)"]
    }

    /// Retailer SKU: meaningless off the host that declared it.
    public static func skuKeys(_ raw: String?, host: String?) -> [String] {
        guard let normalized = ProductIdentityMatching.normalizedID(raw),
              let host, !host.isEmpty
        else { return [] }
        return ["s:\(host.lowercased()):\(normalized)"]
    }

    /// How many name tokens a WRITE files itself under. A name longer than this
    /// files its longest tokens (a long token is the distinctive one — "anc900"
    /// beats "wireless"), so the index can never grow an entry per word of a
    /// marketing paragraph.
    public static let maxIndexedNameTokens = 8
    /// How many name tokens a LOOKUP asks for. Fewer than the write side, and
    /// again the longest: retrieval is a union, so ONE shared token is enough
    /// to surface a record, and each extra token is another dictionary hit.
    public static let maxQueriedNameTokens = 5

    /// The name-bucket keys — the only non-identifier retrieval tier, and the
    /// reason a fuzzy-name match does not have to scan the store.
    ///
    /// A name cannot be a key on its own (two spellings of one product are the
    /// whole point of matching by name), so it is filed per TOKEN, and each
    /// token is scoped the way the fuzzy tier itself is scoped: to the brand
    /// when one is declared, and to the retailer family the page lives on.
    /// A lookup unions the same shape, so a candidate finds an observation as
    /// soon as they share one significant word within one brand or one
    /// retailer — never across the whole store.
    public static func nameKeys(
        _ name: String?, brand: String?, host: String?, limit: Int = maxIndexedNameTokens
    ) -> [String] {
        guard let name, !name.isEmpty else { return [] }
        let tokens = ProductIdentityMatching.nameTokens(name)
            // Longest first, then alphabetical: a deterministic pick, so the
            // same name always files (and asks) under the same tokens.
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0 < $1 }
            .prefix(limit)
        guard !tokens.isEmpty else { return [] }

        var scopes: [String] = []
        if let brandKey = ProductIdentityMatching.comparableBrand(brand) { scopes.append("b:\(brandKey)") }
        if let host, !host.isEmpty {
            scopes.append("h:\(ProductIdentityMatching.registrableDomain(host))")
        }
        guard !scopes.isEmpty else { return [] }
        return orderedUnique(scopes.flatMap { scope in tokens.map { "n:\(scope):\($0)" } })
    }

    /// The weakest key, and the only one that is not an identifier: the page
    /// itself, with the tracking-parameter families `content.js` strips at
    /// capture time removed from both sides.
    public static func urlKey(_ urlString: String) -> String {
        "u:\(strippedTrackingURL(urlString))"
    }

    /// Strips the tracking-parameter families that can differ between two
    /// visits to the same page.
    public static func strippedTrackingURL(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else { return urlString }
        let host = (components.host ?? "").lowercased()
        components.queryItems = components.queryItems?.filter { item in
            let lower = item.name.lowercased()
            if ["srsltid", "gclid", "ref"].contains(lower) { return false }
            if lower.hasPrefix("utm_") { return false }
            if lower == "tag", host.contains("amazon.") { return false }
            return true
        }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url?.absoluteString ?? urlString
    }

    /// Every key a CANDIDATE product should be looked up under.
    ///
    /// Deliberately a SUPERSET of what any one match tier would use: the
    /// flattened `productID` (whose kind was thrown away long before it got
    /// here) is offered at every scope, and the tracker's existing store URLs
    /// join the URL tier. Over-retrieval costs a few record reads; the precise
    /// tier decision is made afterwards, over the retrieved pool.
    public static func candidateKeys(
        gtin: String?, mpn: String?, sku: String?, flattenedID: String?,
        host: String?, urlStrings: [String]
    ) -> [String] {
        var keys: [String] = []
        keys.append(contentsOf: gtinKeys(gtin))
        keys.append(contentsOf: gtinKeys(flattenedID))
        keys.append(contentsOf: mpnKeys(mpn))
        keys.append(contentsOf: mpnKeys(flattenedID))
        keys.append(contentsOf: skuKeys(sku, host: host))
        keys.append(contentsOf: skuKeys(flattenedID, host: host))
        keys.append(contentsOf: retailerKeys(sku, host: host))
        keys.append(contentsOf: retailerKeys(flattenedID, host: host))
        keys.append(contentsOf: urlStrings.map(urlKey))
        return orderedUnique(keys)
    }
}

func orderedUnique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
}
