//
//  WeeklyRowHostTests.swift
//  LunaTests
//

import CryptoKit
import LunaDesignSystem
import LunaModels
import LunaWeekly
import UIKit
import XCTest
@testable import Luna

@MainActor
final class WeeklyRowHostTests: XCTestCase {
    private var container: URL!
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)
    private var store: WeeklySaveStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeeklyRowHostTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
        store = WeeklySaveStore(containerURL: container, now: { self.clock })
        UIView.setAnimationsEnabled(false)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: container)
        container = nil
        UIView.setAnimationsEnabled(true)
        try super.tearDownWithError()
    }

    func testAnEmptyStoreProducesNoRows() {
        let host = makeHost(app: .reader)
        XCTAssertTrue(host.isEmpty)
        XCTAssertTrue(host.rows.isEmpty)
    }

    func testASeededStoreProducesOneRowPerLiveKind() {
        seed(.article, "https://a.example/1")
        seed(.media, "https://b.example/2")
        XCTAssertEqual(makeHost(app: .reader).rows.count, 1)
        XCTAssertEqual(makeHost(app: .luna).rows.count, 2)
        XCTAssertEqual(makeHost(app: .priceTracker).rows.count, 0)
    }

    /// The replacement eclipse: the corona is real, it lives OUTSIDE the
    /// clipping child (its overhang is the whole effect), and the old row is
    /// gone by the time it finishes.
    func testReplacingTheVisibleRowRunsTheEclipse() throws {
        // Animations must be live here: with them off the keyframe run
        // completes immediately and the dressing is torn down before it can be
        // inspected.
        UIView.setAnimationsEnabled(true)
        seed(.article, "https://a.example/1")
        let host = makeHost(app: .reader)
        host.frame = CGRect(x: 0, y: 0, width: 310, height: 82)
        host.layoutIfNeeded()
        let original = try XCTUnwrap(host.rows.first)

        seed(.article, "https://a.example/2")
        host.reload(animated: true)

        XCTAssertTrue(host.isReplacing)
        let corona = try XCTUnwrap(
            host.subviews.compactMap { $0 as? EclipseCoronaView }.first,
            "The corona must be a direct child of the non-clipping host")
        XCTAssertFalse(host.clipsToBounds)
        XCTAssertEqual(corona.frame.size, host.bounds.size)
        XCTAssertEqual(host.rows.count, 1)
        XCTAssertFalse(host.rows[0] === original)

        XCTAssertTrue(try XCTUnwrap(host.rows[0].superview).clipsToBounds)
    }

    func testAnAppearingRowIsNotAnEclipse() {
        UIView.setAnimationsEnabled(true)
        let host = makeHost(app: .reader)
        host.frame = CGRect(x: 0, y: 0, width: 310, height: 82)
        host.layoutIfNeeded()
        seed(.article, "https://a.example/1")
        host.reload(animated: true)
        XCTAssertFalse(host.isReplacing)
        XCTAssertTrue(host.subviews.compactMap { $0 as? EclipseCoronaView }.isEmpty)
    }

    func testAVanishedEntryEmptiesTheHostAndReportsThePresenceChange() {
        seed(.article, "https://a.example/1")
        let host = makeHost(app: .reader)
        var presenceChanges = 0
        host.onPresenceChange = { presenceChanges += 1 }
        store.clear(kind: .article)
        host.reload(animated: true)
        XCTAssertTrue(host.isEmpty)
        XCTAssertEqual(presenceChanges, 1)
    }

    func testTappingARowReportsItsStoredURL() throws {
        seed(.article, "https://a.example/1")
        let host = makeHost(app: .reader)
        var saved: String?
        host.onSave = { url, _ in saved = url }
        try XCTUnwrap(host.rows.first).sendActions(for: .touchUpInside)
        XCTAssertEqual(saved, "https://a.example/1")
    }

    // MARK: - Helpers

    private func makeHost(app: LunaApp) -> WeeklySaveRowHost {
        WeeklySaveRowHost(store: store, app: app, now: { self.clock })
    }

    private func seed(_ kind: WeeklySaveKind, _ url: String) {
        let key = Curve25519.Signing.PrivateKey()
        let save = try! WeeklySigning.sign(
            kind: kind, urlString: url,
            date: clock.addingTimeInterval(-86_400), privateKey: key)
        store.setDisplay(
            WeeklySaveDisplay(
                save: save, title: url, subtitleHost: "example.com", imageData: nil),
            for: kind)
    }
}
