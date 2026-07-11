//
//  ScreenshotDoublePressTests.swift
//  LunaTests
//

import LunaIntents
@testable import LunaStorage
import LunaSend
import XCTest

final class ScreenshotDoublePressTests: XCTestCase {

    private func digest(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: ScreenshotDigest.side * ScreenshotDigest.side)
    }

    func testNilPreviousRunsModel() {
        XCTAssertEqual(ScreenshotDoublePress.decide(newDigest: digest(10), previous: nil), .runModel)
    }

    func testSimilarAndRecentIsDoublePress() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = ScreenshotDoublePressSnapshot(
            digest: digest(10), date: now.addingTimeInterval(-2), savedURLString: "https://example.com/a")
        XCTAssertEqual(
            ScreenshotDoublePress.decide(newDigest: digest(10), previous: previous, now: now),
            .treatAsDoublePress(savedURLString: "https://example.com/a"))
    }

    func testSimilarButOldRunsModel() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = ScreenshotDoublePressSnapshot(
            digest: digest(10), date: now.addingTimeInterval(-30), savedURLString: "https://example.com/a")
        XCTAssertEqual(
            ScreenshotDoublePress.decide(newDigest: digest(10), previous: previous, now: now), .runModel)
    }

    func testDissimilarButRecentRunsModel() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = ScreenshotDoublePressSnapshot(
            digest: digest(10), date: now.addingTimeInterval(-2), savedURLString: "https://example.com/a")
        XCTAssertEqual(
            ScreenshotDoublePress.decide(newDigest: digest(200), previous: previous, now: now), .runModel)
    }

    func testExactlyAtWindowBoundaryRunsModel() {
        // SavePressPolicy.intentDoublePressWindow is compared with a strict
        // `<`, so exactly at the boundary already counts as stale.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = ScreenshotDoublePressSnapshot(
            digest: digest(10),
            date: now.addingTimeInterval(-SavePressPolicy.intentDoublePressWindow),
            savedURLString: "https://example.com/a")
        XCTAssertEqual(
            ScreenshotDoublePress.decide(newDigest: digest(10), previous: previous, now: now), .runModel)
    }

    func testJustInsideWindowIsDoublePress() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = ScreenshotDoublePressSnapshot(
            digest: digest(10),
            date: now.addingTimeInterval(-(SavePressPolicy.intentDoublePressWindow - 0.5)),
            savedURLString: "https://example.com/a")
        XCTAssertEqual(
            ScreenshotDoublePress.decide(newDigest: digest(10), previous: previous, now: now),
            .treatAsDoublePress(savedURLString: "https://example.com/a"))
    }

    // MARK: - ScreenshotDoublePressStore round trip (injected App-Group suite)

    func testStoreRoundTrip() {
        let suiteName = "ScreenshotDoublePressTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)
        ScreenshotDoublePressStore.testDefaultsOverride = defaults
        defer {
            ScreenshotDoublePressStore.testDefaultsOverride = nil
            defaults?.removePersistentDomain(forName: suiteName)
        }

        XCTAssertNil(ScreenshotDoublePressStore.last())

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        ScreenshotDoublePressStore.record(digest: digest(42), savedURLString: "https://example.com/b", now: now)

        let last = ScreenshotDoublePressStore.last()
        XCTAssertEqual(last?.digest, digest(42))
        XCTAssertEqual(last?.savedURLString, "https://example.com/b")
        XCTAssertEqual(last?.date, now)
    }
}
