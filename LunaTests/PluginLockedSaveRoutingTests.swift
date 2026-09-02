//
//  PluginLockedSaveRoutingTests.swift
//  LunaTests
//

import LunaModels
import LunaSavesUI
import UIKit
import XCTest
@testable import Luna

/// A plugin-locked save wears the lock on every kind's card, and its tap goes
/// to the plugin's own browser step rather than the archive unlock
/// (`claudedocs/plans/plugin-platform.md` §8.3).
@MainActor
final class PluginLockedSaveRoutingTests: XCTestCase {

    private final class FakeUnlockRoute: PluginLockedSavePresenting {
        private(set) var asked: [UUID] = []

        func presentPluginUnlock(for item: SavedItem, from presenter: UIViewController) {
            asked.append(item.id)
        }
    }

    private var route: FakeUnlockRoute!
    private var previousRoute: (any PluginLockedSavePresenting)?

    override func setUp() {
        super.setUp()
        route = FakeUnlockRoute()
        previousRoute = PluginLockedSaves.presenter
        PluginLockedSaves.presenter = route
    }

    override func tearDown() {
        PluginLockedSaves.presenter = previousRoute
        super.tearDown()
    }

    private func lockedItem(pluginID: String?, seed: String = "locked") -> SavedItem {
        var item = SavedItem(
            seed: seed, urlString: "https://gate.test/thing", title: "Waiting",
            dateAdded: Date(), state: .needsCaptcha)
        item.pluginID = pluginID
        return item
    }

    private func makeHost() -> CardPresenterHost { CardCarouselHostViewController() }

    // MARK: - The route

    func testOnlyAnOwnedLockGoesToThePluginsBrowserStep() {
        let presenter = UIViewController()
        XCTAssertTrue(
            PluginLockedSaves.presentUnlock(
                for: lockedItem(pluginID: "app.luna.gate"), from: presenter))
        XCTAssertFalse(
            PluginLockedSaves.presentUnlock(for: lockedItem(pluginID: nil), from: presenter),
            "an archive lock has no plugin to ask")
        XCTAssertEqual(route.asked.count, 1)
    }

    func testWithNoPluginPlatformInstalledALockedTapIsNobodysToTake() {
        PluginLockedSaves.presenter = nil
        XCTAssertFalse(
            PluginLockedSaves.presentUnlock(
                for: lockedItem(pluginID: "app.luna.gate"), from: UIViewController()))
    }

    // MARK: - The card face, per kind

    func testAMediaCardDrawsTheLockRatherThanLookingForADownload() {
        let content = MediaCardPresenter().cardContent(
            for: lockedItem(pluginID: "app.luna.gate", seed: "media-locked"), host: makeHost())
        XCTAssertTrue(content is PluginLockedCardContentViewController)
    }

    func testAProductCardDrawsTheLockRatherThanLookingForATracker() {
        let content = ProductCardPresenter().cardContent(
            for: lockedItem(pluginID: "app.luna.gate", seed: "product-locked"), host: makeHost())
        XCTAssertTrue(content is PluginLockedCardContentViewController)
    }

    func testAnUnownedLockLeavesEachKindsCardAsItWas() {
        let item = lockedItem(pluginID: nil, seed: "archive-locked")
        XCTAssertNil(MediaCardPresenter().cardContent(for: item, host: makeHost()))
        XCTAssertNil(ProductCardPresenter().cardContent(for: item, host: makeHost()))
    }

    // MARK: - The taps

    func testAMediaCardsTapRunsTheUnlockInsteadOfTheOpenLadder() {
        let host = makeHost()
        let handled = MediaCardPresenter().itemWasTapped(
            lockedItem(pluginID: "app.luna.gate", seed: "media-tap"),
            cardContent: nil, host: host)
        XCTAssertTrue(handled)
        XCTAssertEqual(route.asked.count, 1)
    }

    func testAProductCardsTapRunsTheUnlockAndStillConsumesTheTap() {
        let host = makeHost()
        let handled = ProductCardPresenter().itemWasTapped(
            lockedItem(pluginID: "app.luna.gate", seed: "product-tap"),
            cardContent: nil, host: host)
        XCTAssertTrue(handled)
        XCTAssertEqual(route.asked.count, 1)
    }
}
