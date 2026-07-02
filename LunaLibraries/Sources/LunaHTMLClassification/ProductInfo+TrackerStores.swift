//
//  ProductInfo+TrackerStores.swift
//  Luna
//

import Foundation
import LunaModels

extension ProductInfo {

    /// The tracker stores a detected product seeds: one per discovered seller
    /// listing, or — for an ordinary single-store product page — the processed
    /// URL itself as the sole store.
    public func trackerStores(fallbackURL: URL) -> [PriceTrackerStore] {
        let now = Date()
        let sellerStores = sellers.map {
            PriceTrackerStore(
                urlString: $0.url.absoluteString,
                lastPrice: $0.price.amount,
                currency: $0.price.currency,
                lastRefreshed: now)
        }
        if !sellerStores.isEmpty { return sellerStores }
        return [PriceTrackerStore(
            urlString: fallbackURL.absoluteString,
            lastPrice: priceAmount,
            currency: priceCurrency,
            lastRefreshed: now)]
    }
}
