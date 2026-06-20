//
//  PriceTrackingManager.swift
//  Clip
//

import Foundation

/// Resolves the current price for a store URL the user adds to an existing
/// tracker. Protocol-based so the view controller can be tested against a mock
/// without the network. Uses the same mandatory `PriceFetcher` strategy (static →
/// embedded JSON → WKWebView render) as save-time and the background refresher.
protocol PriceTrackingManaging {
    /// Fetches the current price at `urlString`, or nil if no price can be found.
    func fetchPrice(urlString: String) async -> ProductPrice?
}

/// Live implementation backed by the shared `PriceFetcher`.
struct PriceTrackingManager: PriceTrackingManaging {
    private let priceFetcher: PriceFetching

    init(priceFetcher: PriceFetching = PriceFetcher()) {
        self.priceFetcher = priceFetcher
    }

    func fetchPrice(urlString: String) async -> ProductPrice? {
        await priceFetcher.fetchPrice(forURLString: urlString, prefetchedHTML: nil)
    }
}
