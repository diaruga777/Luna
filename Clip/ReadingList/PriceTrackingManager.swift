//
//  PriceTrackingManager.swift
//  Clip
//

import Foundation

/// Fetches a store URL and extracts its product price for the price-tracking UI
/// and save flow. Protocol-based so the view controller can be tested against a
/// mock without the network.
protocol PriceTrackingManaging {
    /// Fetches `urlString` and detects its product/price, or nil if the page has
    /// no detectable price.
    func detectProduct(urlString: String) async -> ProductInfo?
}

/// Live implementation backed by the shared article fetcher + the pure detector.
struct PriceTrackingManager: PriceTrackingManaging {
    private let fetcher: HTMLFetching
    private let detector: ProductPageDetector

    init(fetcher: HTMLFetching = ArticleFetcher(), detector: ProductPageDetector = ProductPageDetector()) {
        self.fetcher = fetcher
        self.detector = detector
    }

    func detectProduct(urlString: String) async -> ProductInfo? {
        guard let url = URL(string: urlString),
              let html = try? await fetcher.fetchHTML(from: url) else { return nil }
        return detector.detect(urlString: urlString, html: html)
    }
}
