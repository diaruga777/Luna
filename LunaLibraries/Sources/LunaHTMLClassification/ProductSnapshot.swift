//
//  ProductSnapshot.swift
//  Luna
//

import Foundation

/// One passive product-page visit, captured by a product-handling Safari
/// extension every time a page classifies as a product — independent of
/// whether the Track pill is shown, and NEVER a save (no reading-list row, no
/// refresh, no alert). Snapshots exist only to (a) seed a tracker's history
/// when the user later saves that product (`SnapshotMatcher`,
/// `ProductTrackerIngestor`), and (b) power the "Was $X on <date>" history
/// pill.
///
/// This is the ONE Codable definition of the wire format the extension writes
/// to `productSnapshots.json` in the shared App Group container.
/// `LunaSafari` links no package, so its own copy
/// (`SharedProductSnapshots.Record`) hand-rolls the identical field set —
/// parity between the two is pinned by `SharedProductSnapshotsTests`.
public struct ProductSnapshot: Codable, Equatable {
    /// Product display name at capture time.
    public var name: String
    /// The price, as a decimal string (never a `Double` — precision matters
    /// for later comparisons).
    public var price: String
    /// ISO 4217 currency code, uppercased.
    public var currency: String
    /// The canonical page URL (tracking params stripped) at capture time.
    public var url: String
    /// `url`'s host, stored alongside for cheap grouping/matching.
    public var host: String
    /// UTC calendar day the capture happened on (`yyyy-MM-dd`) — the same
    /// bucketing `PriceDaySnapshot` uses for tracker history.
    public var day: String
    /// Full capture instant (ISO 8601), for diagnostics only.
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

    public init(
        name: String, price: String, currency: String, url: String, host: String,
        day: String, capturedAt: String, gtin: String? = nil, mpn: String? = nil,
        sku: String? = nil, productID: String? = nil, retailerItemID: String? = nil,
        brand: String? = nil
    ) {
        self.name = name
        self.price = price
        self.currency = currency
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
    }

    /// `price` parsed back to a `Decimal`, or nil if the persisted string is malformed.
    public var priceAmount: Decimal? { Decimal(string: price) }
}
