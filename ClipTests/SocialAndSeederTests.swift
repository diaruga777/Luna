//
//  SocialAndSeederTests.swift
//  ClipTests
//
//  Snapshot for the Friends screen + contract tests for the UI-test seeding harness
//  (so the screenshot agent can rely on the named states and the seeding API).
//

import UIKit
import XCTest
@testable import Clip

final class SocialAndSeederTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
    }

    override func tearDown() {
        UITestSupport.wipeSharedStore()
        super.tearDown()
    }

    // MARK: - Friends screen

    // Note: the Friends screen renders a QR code derived from the device's keychain
    // identity, which differs per device/run — it isn't pixel-stable, so it's covered
    // by a layout-sanity assertion (below) and the reading-list "friends button pushes
    // FriendsViewController" navigation test rather than a snapshot comparison.

    func testFriendsScreenLayoutSane() {
        let friends = FriendsViewController()
        let window = UITestSupport.host(UINavigationController(rootViewController: friends))
        LayoutAssertions.assertVisibleAndInBounds(friends.tableView, in: friends.view)
        _ = window
    }

    // MARK: - Seeding harness contract

    /// Every named state seeds the shared store with exactly its fixture items, so
    /// the screenshot agent's `-uiTestState <name>` produces a known list.
    func testEverySeededStateMatchesItsFixture() {
        for state in UITestState.allCases {
            UITestSeeder.seedSharedStore(state)
            let stored = ReadingListStore.shared.items()
            let expected = state.fixture.items
            XCTAssertEqual(stored.count, expected.count,
                           "state \(state.rawValue) seeded \(stored.count) items, fixture has \(expected.count)")
            let storedIDs = Set(stored.map(\.id))
            let expectedIDs = Set(expected.map(\.id))
            XCTAssertEqual(storedIDs, expectedIDs,
                           "state \(state.rawValue) item ids drifted from fixture")
        }
    }

    /// The mixed state really does carry one of every save type the screens render.
    func testMixedStateCoversEverySaveType() {
        UITestSeeder.seedSharedStore(.mixed)
        let items = ReadingListStore.shared.items()

        XCTAssertTrue(items.contains { $0.state == .ready && !$0.isPlatformItem && !$0.isPriceTracker && !$0.isDocument },
                      "missing a ready article")
        XCTAssertTrue(items.contains { $0.state == .needsCaptcha }, "missing a locked article")
        XCTAssertTrue(items.contains { $0.state == .failed }, "missing a failed article")
        XCTAssertTrue(items.contains { $0.isDocument }, "missing a document")
        XCTAssertTrue(items.contains { $0.isYouTubeVideo }, "missing a YouTube video")
        XCTAssertTrue(items.contains { $0.sharedByUsername != nil }, "missing a friend-shared item")
        XCTAssertTrue(items.contains { $0.priceTracker?.isAlerting == true }, "missing an alerting tracker")
        XCTAssertTrue(items.contains { $0.isPriceTracker && $0.priceTracker?.isAlerting == false },
                      "missing a normal tracker")

        // Every non-media platform post plus music + podcast.
        let platforms = Set(items.compactMap { $0.contentPlatform })
        for required in [ContentPlatform.x, .bluesky, .reddit, .tiktok, .instagram, .facebook, .music, .podcast] {
            XCTAssertTrue(platforms.contains(required), "missing platform \(required.rawValue)")
        }
    }

    /// Deterministic ids: seeding twice yields the same item ids (so reference images
    /// stay valid across runs).
    func testSeedingIsDeterministic() {
        UITestSeeder.seedSharedStore(.mixed)
        let first = ReadingListStore.shared.items().map(\.id)
        UITestSeeder.seedSharedStore(.mixed)
        let second = ReadingListStore.shared.items().map(\.id)
        XCTAssertEqual(first, second, "seeding is not deterministic")
    }

    /// Wipe empties the store (the screenshot agent's clean-slate path).
    func testWipeEmptiesStore() {
        UITestSeeder.seedSharedStore(.mixed)
        XCTAssertFalse(ReadingListStore.shared.items().isEmpty)
        ReadingListStore.shared.wipeForTesting()
        XCTAssertTrue(ReadingListStore.shared.items().isEmpty)
    }
}
