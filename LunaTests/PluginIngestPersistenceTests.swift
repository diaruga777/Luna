//
//  PluginIngestPersistenceTests.swift
//  LunaTests
//

import XCTest
import LunaIngest
import LunaModels
import LunaPluginIngest
import LunaPluginKit
import LunaPriceUI
import LunaStorage

/// What a plugin-produced save leaves in the store: the owner on the save and on
/// its tracker's stores, the locked placeholder, and the deferred browser
/// request (`claudedocs/plans/plugin-platform.md` §5.4, §8.1).
final class PluginIngestPersistenceTests: XCTestCase {

    private var directory: URL!
    private var store: SavesStore!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SavesStore(containerURL: directory)
    }

    override func tearDown() {
        store = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - saves.plugin_id

    func testThePluginOwnerSurvivesAReadBack() {
        let item = store.add(urlString: "https://example.com/p/abc")
        store.setPluginID("app.luna.ig", for: item.id)
        XCTAssertEqual(store.item(withID: item.id)?.pluginID, "app.luna.ig")
    }

    func testTheLockedPlaceholderKeepsItsOwnerAndTheCaptchaState() {
        let item = store.add(urlString: "https://example.com/p/abc")
        store.markPluginLocked(item.id, pluginID: "app.luna.ig", title: "Waiting")

        let stored = store.item(withID: item.id)
        XCTAssertEqual(stored?.state, .needsCaptcha, "the lock reuses the archive treatment")
        XCTAssertEqual(stored?.pluginID, "app.luna.ig")
        XCTAssertEqual(stored?.title, "Waiting")
    }

    func testALockNeverDowngradesASaveThatIsAlreadyReadable() {
        let item = store.add(urlString: "https://example.com/p/abc")
        _ = store.saveContent(
            ArticleContent(title: "Read me", blocks: [
                .init(kind: .paragraph, text: String(repeating: "x", length: 20), links: []),
            ]),
            for: item)
        store.markPluginLocked(item.id, pluginID: "p", title: "Waiting")
        XCTAssertEqual(store.item(withID: item.id)?.state, .ready)
    }

    // MARK: - tracker_stores.plugin_id

    func testATrackerFromAPluginStampsEveryStoreWithItsOwner() {
        let item = store.add(urlString: "https://shop.test/thing")
        store.setPluginID("app.luna.shop", for: item.id)
        let tracker = PriceTracker(
            productName: "A Thing",
            stores: [
                PriceTrackerStore(urlString: "https://shop.test/thing", lastPrice: 10, currency: "AUD"),
                PriceTrackerStore(urlString: "https://other.test/thing", lastPrice: 9, currency: "AUD"),
            ],
            brand: nil, productID: nil, identifiers: ProductIdentifiers(),
            alertThresholdFraction: nil)
        _ = store.savePriceTracker(tracker, for: item.id)

        let stored = store.item(withID: item.id)?.priceTracker
        XCTAssertEqual(stored?.stores.map(\.pluginID), ["app.luna.shop", "app.luna.shop"])
    }

    func testASwiftTrackerLeavesItsStoresUnowned() {
        let item = store.add(urlString: "https://shop.test/thing")
        let tracker = PriceTracker(
            productName: "A Thing",
            stores: [PriceTrackerStore(urlString: "https://shop.test/thing", lastPrice: 10, currency: "AUD")],
            brand: nil, productID: nil, identifiers: ProductIdentifiers(),
            alertThresholdFraction: nil)
        _ = store.savePriceTracker(tracker, for: item.id)
        XCTAssertNil(store.item(withID: item.id)?.priceTracker?.stores.first?.pluginID)
    }

    // MARK: - plugin_browser_requests

    func testABrowserRequestIsPendingUntilItIsCompletedAndItsResultIsSingleUse() {
        let item = store.add(urlString: "https://example.com/p/abc")
        let requests = PluginBrowserRequestStore(saves: store)
        requests.put(saveID: item.id, pluginID: "app.luna.ig", requestJSON: #"{"url":"x"}"#)

        XCTAssertEqual(requests.pending(for: item.id)?.pluginID, "app.luna.ig")
        XCTAssertEqual(requests.pending(for: item.id)?.requestJSON, #"{"url":"x"}"#)

        requests.complete(saveID: item.id, resultJSON: #"{"html":"<p>ok</p>"}"#)
        XCTAssertNil(requests.pending(for: item.id), "a completed request no longer blocks")
        XCTAssertEqual(requests.takeResult(saveID: item.id), #"{"html":"<p>ok</p>"}"#)
        XCTAssertNil(
            requests.takeResult(saveID: item.id),
            "the result is taken once, so a second browser ask presents the modal again")
    }

    func testDeletingASaveTakesItsBrowserRequestWithIt() {
        let item = store.add(urlString: "https://example.com/p/abc")
        let requests = PluginBrowserRequestStore(saves: store)
        requests.put(saveID: item.id, pluginID: "p", requestJSON: "{}")
        store.delete(item)
        XCTAssertNil(requests.record(for: item.id), "the row cascades with its save")
    }

    // MARK: - pending_plugin_models

    func testASafariHandOffIsDrainedOnce() {
        let pending = PendingPluginModelStore(saves: store)
        pending.clear()
        pending.put(PendingPluginModel(
            urlString: "https://example.com/p/abc",
            modelJSON: #"{"kind":"media","assets":[]}"#, pluginID: "app.luna.ig"))

        XCTAssertEqual(pending.peek().count, 1)
        XCTAssertEqual(pending.takeAll().first?.pluginID, "app.luna.ig")
        XCTAssertTrue(pending.takeAll().isEmpty, "draining removes what it handed over")
    }

    func testAnExpiredHandOffIsNotDrained() {
        let pending = PendingPluginModelStore(saves: store)
        pending.clear()
        pending.put(PendingPluginModel(
            urlString: "https://example.com/p/abc", modelJSON: "{}", pluginID: "p",
            createdAt: Date(timeIntervalSinceNow: -PendingPluginModelStore.lifetime - 60)))
        XCTAssertTrue(
            pending.peek().isEmpty,
            "a hand-off the user never returned for is scratch — its CDN URLs are dead anyway")
    }
}

private extension String {
    init(repeating character: String, length: Int) {
        self = String(repeating: character, count: length)
    }
}
