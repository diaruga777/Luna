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
        hostWindow?.isHidden = true
        hostWindow = nil
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

    // MARK: - Central-app cycling

    func testTheCycleRunsOnlyWithTwoLiveKindsAndTheCardInFront() {
        seed(.article, "https://a.example/1")
        let clock = FakeCycleClock()
        let host = makeHost(app: .luna, pacer: clock.pacer)
        host.frame = CGRect(x: 0, y: 0, width: 310, height: 82)
        window(host)
        host.cardDidBecomeCentered()
        XCTAssertFalse(clock.pacer.isRunning, "One live kind never cycles")

        seed(.media, "https://b.example/2")
        host.reload(animated: false)
        XCTAssertTrue(clock.pacer.isRunning)

        host.cardDidLeaveCenter()
        XCTAssertFalse(clock.pacer.isRunning, "A card off centre stops cycling")
    }

    func testATickAdvancesToTheNextKind() {
        seed(.article, "https://a.example/1")
        seed(.media, "https://b.example/2")
        let clock = FakeCycleClock()
        let host = makeHost(app: .luna, pacer: clock.pacer)
        host.frame = CGRect(x: 0, y: 0, width: 310, height: 82)
        window(host)
        host.cardDidBecomeCentered()

        XCTAssertEqual(clock.interval, WeeklyCyclePacer.interval)
        XCTAssertFalse(host.rows[1].isHidden == false)
        clock.tick()
        XCTAssertFalse(host.rows[1].isHidden, "The neighbour is on screen after a tick")
    }

    func testAManualGestureLatchesAutoAdvanceOffUntilTheCardLeavesOrTheAppReturns() {
        let pacer = WeeklyCyclePacer(scheduler: { _, _ in {} })
        pacer.liveKindCount = 2
        pacer.isInWindow = true
        pacer.isCentered = true
        XCTAssertTrue(pacer.canRun)

        pacer.userDidTakeControl()
        XCTAssertFalse(pacer.canRun)
        XCTAssertTrue(pacer.userTookControl)

        // Leaving centre drops the latch (and stops for the other reason).
        pacer.cardDidLeaveCenter()
        XCTAssertFalse(pacer.userTookControl)
        pacer.isCentered = true
        XCTAssertTrue(pacer.canRun)

        // So does a background → foreground round trip.
        pacer.userDidTakeControl()
        pacer.appDidEnterBackground()
        XCTAssertFalse(pacer.canRun)
        pacer.appWillEnterForeground()
        XCTAssertTrue(pacer.canRun)
    }

    func testReduceMotionAndAReplacementBothSuppressTheCycle() {
        let pacer = WeeklyCyclePacer(scheduler: { _, _ in {} })
        pacer.liveKindCount = 3
        pacer.isInWindow = true
        pacer.isCentered = true
        XCTAssertTrue(pacer.canRun)

        pacer.reduceMotion = true
        XCTAssertFalse(pacer.canRun)
        pacer.reduceMotion = false

        pacer.isReplacing = true
        XCTAssertFalse(pacer.canRun)
        pacer.isReplacing = false

        pacer.isUserTouching = true
        XCTAssertFalse(pacer.canRun)
    }

    /// A single-kind app never cycles, so a faceted app's host is inert.
    func testAFacetedAppNeverStartsThePacer() {
        seed(.article, "https://a.example/1")
        let clock = FakeCycleClock()
        let host = makeHost(app: .reader, pacer: clock.pacer)
        host.frame = CGRect(x: 0, y: 0, width: 310, height: 82)
        window(host)
        host.cardDidBecomeCentered()
        XCTAssertFalse(clock.pacer.isRunning)
    }

    // MARK: - Helpers

    /// A pacer whose cadence the test drives by hand.
    private final class FakeCycleClock {
        private(set) var interval: TimeInterval = 0
        private var tickBlock: (() -> Void)?
        lazy var pacer = WeeklyCyclePacer(scheduler: { [weak self] interval, tick in
            self?.interval = interval
            self?.tickBlock = tick
            return { [weak self] in self?.tickBlock = nil }
        })
        func tick() { tickBlock?() }
    }

    private var hostWindow: UIWindow?

    private func window(_ host: WeeklySaveRowHost) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.addSubview(host)
        window.isHidden = false
        hostWindow = window
        host.layoutIfNeeded()
    }

    private func makeHost(
        app: LunaApp, pacer: WeeklyCyclePacer = WeeklyCyclePacer()
    ) -> WeeklySaveRowHost {
        WeeklySaveRowHost(store: store, app: app, now: { self.clock }, pacer: pacer)
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
