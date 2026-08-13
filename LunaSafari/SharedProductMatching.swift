//
//  SharedProductMatching.swift
//  LunaSafari
//

import Foundation
import LunaPriceCompare

/// Answers the "Was $X on <date>" history-pill query inside the extension
/// process: matches the page's extracted product data against the app-written
/// tracked-product index and the stored observations, then reduces the matches
/// to the one line a pill can carry.
///
/// The matching itself is `LunaPriceCompare.ProductPageMatching`, which the app
/// links too; what lives here is the reduction — every point both sources hold
/// for this product, and the lowest of them that beats the page's own price.
enum SharedProductMatching {

    struct HistoryAnswer {
        var isTracked: Bool
        var hasHistory: Bool
        var amount: String?
        var currency: String?
        var day: String?
    }

    /// The full answer for a page's extracted snapshot payload (the same shape
    /// `extractProductSnapshot()` sends as `productSnapshot`).
    static func historyAnswer(forPageSnapshot page: ProductSnapshot) -> HistoryAnswer {
        let index = PriceHistoryIndex.load()
        let trackedMatch = index.first { ProductPageMatching.matches(page: page, indexEntry: $0) }

        var points: [(price: Decimal, currency: String, day: String)] = []
        if let trackedMatch {
            for store in trackedMatch.stores {
                for point in store.points {
                    if let amount = Decimal(string: point.price) {
                        points.append((amount, point.currency, point.day))
                    }
                }
            }
        }
        // Indexed: only observations filed under one of this page's own
        // identifiers are opened, never the whole store.
        let otherSnapshots = ProductSnapshotStore.shared
            .snapshots(forKeys: page.indexKeys)
            .filter { $0.url != page.url }
        for snapshot in otherSnapshots
        where ProductPageMatching.matches(page: page, snapshot: snapshot) {
            if let amount = Decimal(string: snapshot.price) {
                points.append((amount, snapshot.currency, snapshot.day))
            }
        }

        guard let pageAmount = Decimal(string: page.price) else {
            return HistoryAnswer(
                isTracked: trackedMatch != nil, hasHistory: false, amount: nil, currency: nil, day: nil)
        }
        let cheaper = points.filter { $0.currency == page.currency && $0.price < pageAmount }
        guard let lowest = cheaper.min(by: {
            $0.price != $1.price ? $0.price < $1.price : $0.day < $1.day
        }) else {
            return HistoryAnswer(
                isTracked: trackedMatch != nil, hasHistory: false, amount: nil, currency: nil, day: nil)
        }
        return HistoryAnswer(
            isTracked: trackedMatch != nil, hasHistory: true,
            amount: NSDecimalNumber(decimal: lowest.price).stringValue,
            currency: lowest.currency, day: lowest.day)
    }
}
