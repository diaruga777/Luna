//
//  SafariExtensionStatusStoreTests.swift
//  LunaTests
//

import LunaStorage
import XCTest

final class SafariExtensionStatusStoreTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var store: SafariExtensionStatusStore!

    override func setUp() {
        super.setUp()
        suiteName = "SafariExtensionStatusStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        store = SafariExtensionStatusStore(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        store = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testNotEnabledByDefault() {
        XCTAssertFalse(store.isEnabled(forSurface: "reader"))
        XCTAssertFalse(store.hasRun(forSurface: "reader"))
        XCTAssertNil(store.enabledDate(forSurface: "reader"))
    }

    func testRecordEnabledRoundTrips() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        store.recordEnabled(forSurface: "reader", date: date)
        XCTAssertTrue(store.hasRun(forSurface: "reader"))
        XCTAssertTrue(store.isEnabled(forSurface: "reader"))
        XCTAssertEqual(store.enabledDate(forSurface: "reader"), date)
    }

    func testBooleanHasRunIsEnoughToReportEnabled() {
        defaults.set(true, forKey: "safariExtensionHasRun.reader")
        XCTAssertTrue(store.hasRun(forSurface: "reader"))
        XCTAssertTrue(store.isEnabled(forSurface: "reader"))
        XCTAssertNil(store.enabledDate(forSurface: "reader"))
    }

    func testLegacyTimestampIsEnoughToReportEnabled() {
        defaults.set(1_700_000_000.0, forKey: "safariExtensionEnabled.reader")
        XCTAssertFalse(store.hasRun(forSurface: "reader"))
        XCTAssertTrue(store.isEnabled(forSurface: "reader"))
        XCTAssertEqual(store.enabledDate(forSurface: "reader"), Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testEnabledStateIsPerSurface() {
        store.recordEnabled(forSurface: "reader")
        XCTAssertTrue(store.isEnabled(forSurface: "reader"))
        XCTAssertFalse(store.isEnabled(forSurface: "downloader"))
    }

    func testTakeoverPendingDefaultsFalse() {
        XCTAssertFalse(store.isTakeoverPending(forSurface: "reader"))
    }

    func testTakeoverPendingRoundTripsAndIsPerSurface() {
        store.setTakeoverPending(true, forSurface: "reader")
        XCTAssertTrue(store.isTakeoverPending(forSurface: "reader"))
        XCTAssertFalse(store.isTakeoverPending(forSurface: "downloader"))

        store.setTakeoverPending(false, forSurface: "reader")
        XCTAssertFalse(store.isTakeoverPending(forSurface: "reader"))
    }
}
