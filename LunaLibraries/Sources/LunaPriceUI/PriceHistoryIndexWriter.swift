//
//  PriceHistoryIndexWriter.swift
//  LunaPriceUI
//

import LunaAppConfig
import LunaModels
import LunaStorage
import Foundation

/// One tracked product's compact history, as written to the shared App Group
/// `priceHistoryIndex.json` — the app-maintained counterpart to
/// `ProductSnapshot` the Safari extension can't get any other way (the
/// extension is package-free and `readingList.json` is both too large and not
/// a format worth hand-parsing in an appex).
public struct PriceHistoryIndexEntry: Codable, Equatable {
    public struct Point: Codable, Equatable {
        public var day: String
        public var price: String
        public var currency: String

        public init(day: String, price: String, currency: String) {
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

/// Regenerates the compact price-history index every product-handling app's
/// Safari extension queries to answer the "Was $X on <date>" history pill and
/// to tell whether the page it's on is already tracked. Whole-file, atomic —
/// regenerated (not incrementally patched) after `ProductTrackerIngestor`
/// persists a save, after each `PriceRefresher` run, and from the product
/// apps' `KindWiring.appDidEnterBackground`. Only `Luna` and `LunaPriceTracker`
/// link `LunaPriceUI`, so only those two ever write it — correct, since only
/// they can have trackers to index.
public enum PriceHistoryIndexWriter {
    /// Mirrors `LunaSafari/SharedProductMatching.swift`'s constants exactly —
    /// `SharedProductSnapshotsTests` pins both copies to these literal values.
    public static let relativeDirectory = "Library/ProductSnapshots"
    public static let fileName = "priceHistoryIndex.json"
    public static let maxPointsAgeDays = 365

    public static func fileURL() -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: AppConfig.appGroupID)?
            .appendingPathComponent(relativeDirectory, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    /// Builds the index entries from the given trackers (pure — testable
    /// without touching the App Group container).
    public static func makeEntries(
        from trackers: [PriceTracker], now: Date = Date()
    ) -> [PriceHistoryIndexEntry] {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let cutoff = utcCalendar.date(byAdding: .day, value: -maxPointsAgeDays, to: now) ?? now

        return trackers.filter { !$0.isArchived }.map { tracker in
            let stores = tracker.stores.map { store -> PriceHistoryIndexEntry.StorePoints in
                let host = URL(string: store.urlString)?.host ?? store.urlString
                let points = store.priceHistory
                    .filter { $0.dayStart >= cutoff }
                    .map {
                        PriceHistoryIndexEntry.Point(
                            day: dayFormatter.string(from: $0.dayStart),
                            price: NSDecimalNumber(decimal: $0.lowestPrice).stringValue,
                            currency: $0.currency)
                    }
                return PriceHistoryIndexEntry.StorePoints(url: store.urlString, host: host, points: points)
            }
            return PriceHistoryIndexEntry(
                name: tracker.productName, brand: tracker.brand, productID: tracker.productID,
                stores: stores)
        }
    }

    /// Regenerates the whole file from every non-archived tracker currently in
    /// the reading list.
    public static func regenerate(store: ReadingListStore = .shared, now: Date = Date()) {
        let trackers = store.items().compactMap(\.priceTracker)
        write(makeEntries(from: trackers, now: now))
    }

    public static func write(_ entries: [PriceHistoryIndexEntry]) {
        guard let fileURL = fileURL() else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Test/tooling seam — reads the file back.
    public static func load() -> [PriceHistoryIndexEntry] {
        guard let fileURL = fileURL(), let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([PriceHistoryIndexEntry].self, from: data)) ?? []
    }
}
