//
//  CardCarouselPullTabHintTests.swift
//  LunaTests
//

import XCTest
@testable import LunaDesignSystem

final class CardCarouselPullTabHintTests: XCTestCase {

    func testSwipeMarkerIsSharedByEveryStoreUsingTheSameDefaultsSuite() {
        let suite = "CardCarouselPullTabHintTests.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let firstApp = CardCarouselPullTabHintStore(defaults: defaults)
        let secondApp = CardCarouselPullTabHintStore(defaults: defaults)

        XCTAssertFalse(firstApp.hasSeenCardPagingSwipe)
        XCTAssertFalse(secondApp.hasSeenCardPagingSwipe)

        firstApp.recordCardPagingSwipe()

        XCTAssertTrue(secondApp.hasSeenCardPagingSwipe,
                      "A swipe in one Luna app must retire the tutorial in the others.")
    }
}
