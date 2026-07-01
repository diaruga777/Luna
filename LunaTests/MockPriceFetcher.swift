//
//  MockPriceFetcher.swift
//  LunaTests
//

import LunaPriceUI
import LunaHTMLClassification
import Foundation
@testable import Luna

/// A test double for `PriceFetching` that returns canned prices keyed by the
/// requested URL string, recording every call. A missing entry resolves to nil
/// (no price found by any method), mirroring the real fetcher's article fallback.
final class MockPriceFetcher: PriceFetching {
    /// Price returned for a given absolute URL string. A missing entry yields nil.
    var priceByURL: [String: ProductPrice] = [:]
    /// URL strings the mock was asked to fetch, in order.
    private(set) var requestedURLs: [String] = []

    func fetchPrice(forURLString urlString: String, prefetchedHTML: String?) async -> ProductPrice? {
        requestedURLs.append(urlString)
        return priceByURL[urlString]
    }
}
