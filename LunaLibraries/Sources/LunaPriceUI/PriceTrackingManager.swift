//
//  PriceTrackingManager.swift
//  Luna
//

import LunaHTMLClassification
import Foundation

/// Resolves the current price for a store URL the user adds to an existing
/// tracker. Protocol-based so the view controller can be tested against a mock
/// without the network. Uses the same mandatory `PriceFetcher` strategy (static →
/// embedded JSON → WKWebView render) as save-time and the background refresher.
public protocol PriceTrackingManaging {
    /// Fetches the current price at `urlString`, or nil if no price can be found.
    /// `prefetchedHTML` (e.g. the rendered HTML the search overlay already captured)
    /// lets the fetcher take its fast static/embedded path without a redundant
    /// network round-trip; pass nil to have it fetch.
    func fetchPrice(urlString: String, prefetchedHTML: String?) async -> ProductPrice?
}

public extension PriceTrackingManaging {
    /// Convenience for the paste-a-URL add path, which has no prefetched HTML.
    public func fetchPrice(urlString: String) async -> ProductPrice? {
        await fetchPrice(urlString: urlString, prefetchedHTML: nil)
    }
}

/// Live implementation backed by the shared `PriceFetcher`.
public struct PriceTrackingManager: PriceTrackingManaging {
    private let priceFetcher: PriceFetching

    public init(priceFetcher: PriceFetching = PriceFetcher()) {
        self.priceFetcher = priceFetcher
    }

    public func fetchPrice(urlString: String, prefetchedHTML: String?) async -> ProductPrice? {
        await priceFetcher.fetchPrice(forURLString: urlString, prefetchedHTML: prefetchedHTML)
    }
}
