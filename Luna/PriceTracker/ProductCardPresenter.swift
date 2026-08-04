//
//  ProductCardPresenter.swift
//  Luna
//
//  The product kind's card behavior, defined ONCE for every app that shows a
//  price tracker — Luna Price Tracker and the central Luna app. Compiled into
//  exactly those two targets.
//
//  The central app used to render a tracked product as a generic link card
//  ("Tap to see price history") while `PriceTrackerCardsViewController` — with
//  the real in-card editor — sat compiled into the same binary, unreachable. The
//  editor, the tag badge, the product thumbnail, the price-alert acknowledgement
//  and the price-sensitive fingerprint all live here now, so both apps show the
//  same card.
//

import LunaDesignSystem
import LunaModels
import LunaPriceUI
import LunaStorage
import UIKit

@MainActor
final class ProductCardPresenter: CardKindPresenting {

    private let store = ReadingListStore.shared

    // MARK: - Slot data

    /// A price change must re-render the card. The central app's fingerprint had
    /// no price component at all, so a tracker whose price moved kept drawing
    /// its old graph until something else forced a reload.
    func fingerprint(for item: ReadingListItem) -> String {
        guard let tracker = item.priceTracker else { return "" }
        let stores = tracker.stores.map {
            "\($0.urlString)|\($0.lastPrice.map(String.init(describing:)) ?? "")"
                + "|\($0.priceHistory.count)"
        }.joined(separator: ";")
        return [
            tracker.productName,
            tracker.imageFileName ?? "",
            // "none" is a real state: a tracker with no alert threshold at all.
            tracker.alertThresholdFraction.map { String($0) } ?? "none",
            String(tracker.isArchived),
            stores,
        ].joined(separator: "|")
    }

    /// A tracker's archived flag lives on the tracker, not on the row.
    func isArchived(_ item: ReadingListItem) -> Bool {
        item.isArchived || item.priceTracker?.isArchived == true
    }

    func title(for item: ReadingListItem) -> String? {
        item.priceTracker?.productName
    }

    /// A product is marked by its tag, never by its seller's favicon.
    func loadSourceBadge(
        for item: ReadingListItem, completion: @escaping (CarouselSourceBadge?) -> Void
    ) {
        completion(.symbol("tag.fill"))
    }
}
