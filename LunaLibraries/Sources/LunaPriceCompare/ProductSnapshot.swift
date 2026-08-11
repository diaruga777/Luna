//
//  ProductSnapshot.swift
//  LunaPriceCompare
//

import Foundation
import LunaModels

/// One product observation: what the product is, what it cost, and when.
///
/// A snapshot is written for EVERY product page any Luna process observes and
/// for every alternative-seller result a fan-out returns — unconditionally, with
/// no setting anywhere able to suppress it (`claudedocs/price-tracking.md`'s
/// "Product snapshots"). It is never a save: no reading-list row, no refresh, no
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
    /// UTC calendar day the capture happened on (`yyyy-MM-dd`) — the same
    /// bucketing `PriceDaySnapshot` uses for tracker history.
    public var day: String
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
        url: String, host: String, day: String, capturedAt: String,
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
        ISO8601DateFormatter().date(from: capturedAt) ?? ProductSnapshotStore.date(forDay: day)
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
