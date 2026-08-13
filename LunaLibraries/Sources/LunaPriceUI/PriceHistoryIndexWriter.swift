//
//  PriceHistoryIndexWriter.swift
//  LunaPriceUI
//

import LunaModels
import LunaPriceCompare
import LunaStorage
import Foundation

/// Regenerates the compact price-history index every product-handling app's
/// Safari extension queries to answer the "Was $X on <date>" history pill and
/// to tell whether the page it's on is already tracked. Whole-file, atomic —
/// regenerated (not incrementally patched) after `ProductTrackerIngestor`
/// persists a save, after each `PriceRefresher` run, and from the product
/// apps' `KindWiring.appDidEnterBackground`. Only `Luna` and `LunaPriceTracker`
/// link `LunaPriceUI`, so only those two ever write it — correct, since only
/// they can have trackers to index.
public enum PriceHistoryIndexWriter {
    public static let maxPointsAgeDays = 365

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
                            day: ProductSnapshotStore.dayString(for: $0.dayStart),
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
    /// the saves list.
    public static func regenerate(store: SavesStore = .shared, now: Date = Date()) {
        let trackers = store.items().compactMap(\.priceTracker)
        write(makeEntries(from: trackers, now: now))
    }

    public static func write(_ entries: [PriceHistoryIndexEntry]) {
        guard let fileURL = PriceHistoryIndex.fileURL() else { return }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
