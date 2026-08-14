//
//  TrackedProductHistory.swift
//  LunaPriceCompare
//

import Foundation
import LunaModels

/// One tracked product's compact history, in the shape the page matcher and the
/// alternative-seller finder ask questions in — the tracked-product counterpart
/// to `ProductSnapshot`.
///
/// Built in memory from a `PriceTracker`; it used to be decoded from an App Group
/// `priceHistoryIndex.json` that the two product apps regenerated whole on every
/// refresh. The Safari extensions link `LunaStorage` and hold the App Group
/// entitlement, so they read the tracker rows directly and the file is gone.
///
/// A projection, deliberately lossy: it flattens the tracker's keyed identifiers
/// into one `productID` and drops each point's FX rate, because those are what the
/// matcher below compares. Reading the tracker gives more than this carries, so a
/// future matcher tier can ask for more without a file to regenerate.
public struct PriceHistoryIndexEntry: Codable, Equatable {
    public struct Point: Codable, Equatable {
        public var day: UTCDay
        public var price: String
        public var currency: String

        public init(day: UTCDay, price: String, currency: String) {
            self.day = day
            self.price = price
            self.currency = currency
        }
    }

    public struct StorePoints: Codable, Equatable {
        public var url: String
        public var host: String
        public var points: [Point]

        public init(url: String, host: String, points: [Point]) {
            self.url = url
            self.host = host
            self.points = points
        }
    }

    public var name: String
    public var brand: String?
    public var productID: String?
    public var stores: [StorePoints]

    public init(name: String, brand: String?, productID: String?, stores: [StorePoints]) {
        self.name = name
        self.brand = brand
        self.productID = productID
        self.stores = stores
    }
}

public extension PriceHistoryIndexEntry {

    /// A tracker's history in the matcher's terms.
    ///
    /// `UTCDay(point.dayStart)` is the same relabelling the retired writer did —
    /// the stored instant is a LOCAL start-of-day, and the pill has always shown it
    /// as a UTC day. Keeping the conversion keeps the pill's text identical.
    init(tracker: PriceTracker, since cutoff: Date? = nil) {
        self.init(
            name: tracker.productName,
            brand: tracker.brand,
            productID: tracker.productID,
            stores: tracker.stores.map { store in
                StorePoints(
                    url: store.urlString,
                    host: URL(string: store.urlString)?.host ?? store.urlString,
                    points: store.priceHistory
                        .filter { cutoff == nil || $0.dayStart >= cutoff! }
                        .map {
                            Point(
                                day: UTCDay($0.dayStart),
                                price: NSDecimalNumber(decimal: $0.lowestPrice).stringValue,
                                currency: $0.currency)
                        })
            })
    }
}
