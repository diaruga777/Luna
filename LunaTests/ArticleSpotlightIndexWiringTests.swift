//
//  ArticleSpotlightIndexWiringTests.swift
//  LunaTests
//

import LunaModels
import XCTest
@testable import Luna

/// The two pure pieces of `ArticleSpotlightIndexWiring`'s sweep: which items
/// it turns into Spotlight entities, and which previously-indexed identifiers
/// it deletes. The side-effecting half (the real `CSSearchableIndex` calls)
/// isn't under test — there's nothing to fake it against without a synthesized
/// mock, which the sweep would never actually exercise.
final class ArticleSpotlightIndexWiringTests: XCTestCase {

    private func item(
        seed: String, state: ReadingListItem.State = .ready,
        platform: ContentPlatform? = nil, priceTracker: PriceTracker? = nil
    ) -> ReadingListItem {
        ReadingListItem(
            seed: seed, urlString: "https://example.com/\(seed)", title: "Article \(seed)",
            dateAdded: Date(timeIntervalSince1970: 1_700_000_000), state: state,
            platform: platform, priceTracker: priceTracker)
    }

    // MARK: - indexableEntities

    func testIndexableEntitiesKeepsOnlyReadableArticles() {
        let readable = item(seed: "readable")
        let pending = item(seed: "pending", state: .pending)
        let video = item(seed: "video", platform: .youtube)
        let product = item(seed: "product", priceTracker: PriceTracker(
            productName: "Widget", firstStoreURL: "https://example.com/product",
            price: 10, currency: "USD"))

        let entities = ArticleSpotlightIndexWiring.indexableEntities(
            from: [readable, pending, video, product])

        XCTAssertEqual(entities.map(\.id), [readable.id], "only the ready, non-platform, non-tracker item is indexable")
    }

    func testIndexableEntitiesIsEmptyForNoItems() {
        XCTAssertTrue(ArticleSpotlightIndexWiring.indexableEntities(from: []).isEmpty)
    }

    // MARK: - removedIdentifiers

    func testRemovedIdentifiersIsThePreviousIDsNoLongerCurrent() {
        let removed = ArticleSpotlightIndexWiring.removedIdentifiers(
            previousIDs: ["a", "b", "c"], currentIDs: ["b"])
        XCTAssertEqual(Set(removed), ["a", "c"])
    }

    func testRemovedIdentifiersIsEmptyWhenNothingDropped() {
        let removed = ArticleSpotlightIndexWiring.removedIdentifiers(
            previousIDs: ["a", "b"], currentIDs: ["a", "b", "c"])
        XCTAssertTrue(removed.isEmpty)
    }
}
