//
//  PriceHistoryIndex.swift
//  LunaPriceCompare
//

import Foundation
import LunaAppConfig

/// One tracked product's compact history, as written to the shared App Group
/// `priceHistoryIndex.json` — the tracked-product counterpart to
/// `ProductSnapshot`, small enough for an appex to read whole (a tracker's own
/// rows in the saves database are spread over four tables, which is more machinery
/// than a Safari extension asking one question should need).
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

/// Where the compact tracked-product index lives, and how to read it.
///
/// It sits beside the snapshot store's own files, in the same App Group
/// directory, and for the same reason the store lives here: the two product apps
/// write it (`PriceHistoryIndexWriter`, LunaPriceUI — only they can have
/// trackers) while their Safari extensions read it to answer the "Was $X on
/// <date>" pill, and this is the one kind module all of those processes link.
public enum PriceHistoryIndex {
    public static let fileName = "priceHistoryIndex.json"

    public static func fileURL() -> URL? {
        AppConfig.sharedContainerURL()?
            .appendingPathComponent(ProductSnapshotStore.relativeDirectory, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// The whole index, or `[]` when nothing has been written yet.
    public static func load() -> [PriceHistoryIndexEntry] {
        guard let fileURL = fileURL(), let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([PriceHistoryIndexEntry].self, from: data)) ?? []
    }
}
