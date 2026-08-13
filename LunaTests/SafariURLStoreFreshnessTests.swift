//
//  SafariURLStoreFreshnessTests.swift
//  LunaTests
//

@testable import LunaStorage
import XCTest

final class SafariURLStoreFreshnessTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SafariURLStoreFreshnessTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        SafariURLStore.testDefaultsOverride = defaults
    }

    override func tearDown() {
        SafariURLStore.testDefaultsOverride = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    private func write(url: String?, date: Date?) {
        if let url {
            defaults.set(url, forKey: SafariURLStore.urlKey)
        } else {
            defaults.removeObject(forKey: SafariURLStore.urlKey)
        }
        if let date {
            defaults.set(date.timeIntervalSince1970, forKey: SafariURLStore.dateKey)
        } else {
            defaults.removeObject(forKey: SafariURLStore.dateKey)
        }
    }

    /// The write side, which the Safari extensions' native handler owns: the URL
    /// the app later reads, and the instant its freshness is measured from.
    func testRecordingAPageMakesItTheLastURLAtThatMoment() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        SafariURLStore.record("https://example.com/story", at: now)
        XCTAssertEqual(SafariURLStore.lastURL, "https://example.com/story")
        XCTAssertEqual(SafariURLStore.lastDate, now)
        XCTAssertTrue(SafariURLStore.isFresh(now: now))

        SafariURLStore.record("https://example.com/next", at: now.addingTimeInterval(30))
        XCTAssertEqual(SafariURLStore.lastURL, "https://example.com/next")
        XCTAssertEqual(SafariURLStore.lastDate, now.addingTimeInterval(30))
    }

    func testAbsentIsNotFresh() {
        write(url: nil, date: nil)
        XCTAssertFalse(SafariURLStore.isFresh())
    }

    func testEmptyURLIsNotFresh() {
        write(url: "", date: Date())
        XCTAssertFalse(SafariURLStore.isFresh())
    }

    func testRecentURLIsFresh() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        write(url: "https://example.com/story", date: now.addingTimeInterval(-60))
        XCTAssertTrue(SafariURLStore.isFresh(now: now))
    }

    func testStaleURLIsNotFresh() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        write(url: "https://example.com/story", date: now.addingTimeInterval(-(SafariURLStore.freshnessWindow + 1)))
        XCTAssertFalse(SafariURLStore.isFresh(now: now))
    }

    func testExactlyAtWindowBoundaryIsFresh() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        write(url: "https://example.com/story", date: now.addingTimeInterval(-SafariURLStore.freshnessWindow))
        XCTAssertTrue(SafariURLStore.isFresh(now: now))
    }

    func testJustPastWindowBoundaryIsNotFresh() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        write(url: "https://example.com/story",
              date: now.addingTimeInterval(-SafariURLStore.freshnessWindow - 1))
        XCTAssertFalse(SafariURLStore.isFresh(now: now))
    }

    func testDateWithoutURLIsNotFresh() {
        write(url: nil, date: Date())
        XCTAssertFalse(SafariURLStore.isFresh())
    }

    func testCustomWindowIsRespected() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        write(url: "https://example.com/story", date: now.addingTimeInterval(-30))
        XCTAssertFalse(SafariURLStore.isFresh(within: 10, now: now))
        XCTAssertTrue(SafariURLStore.isFresh(within: 60, now: now))
    }
}
