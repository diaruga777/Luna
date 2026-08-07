//
//  RSVPEyeTrackingReliabilityTests.swift
//  LunaTests
//
//  Regression coverage for confidence handling and the manual-resume latch.
//

import LunaDesignSystem
import LunaModels
import LunaReaderUI
import LunaStorage
import UIKit
import XCTest
@testable import Luna

private final class ReliabilityGazeTracker: GazeTracking {
    var onSample: ((GazeSample) -> Void)?
    var isRunning = false
    func start() { isRunning = true }
    func stop() { isRunning = false }
}

final class RSVPEyeTrackingReliabilityTests: XCTestCase {

    private var tracker = ReliabilityGazeTracker()
    private var window: UIWindow?
    private let content = UITestFixtures.sampleArticleContent(title: "Gaze Reliability Fixture")
    private var item: ReadingListItem {
        ReadingListItem(seed: "gaze-reliability", urlString: "https://example.com/gaze",
                        title: "Gaze Reliability Fixture", dateAdded: UITestFixtures.baseDate,
                        state: .ready, wordCount: 480)
    }

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
        GazeTrackingAvailability.supportOverride = true
        GazeTrackingPermission.statusOverride = .granted
        ReaderSettings.eyeTrackingEnabled = false
        ReaderSettings.rsvpMode = .words
        tracker = ReliabilityGazeTracker()
    }

    override func tearDown() {
        GazeTrackingAvailability.supportOverride = nil
        GazeTrackingPermission.statusOverride = nil
        ReaderSettings.eyeTrackingEnabled = false
        window = nil
        super.tearDown()
    }

    private func makeReader() -> RSVPViewController {
        let reader = RSVPViewController(item: item, content: content)
        reader.gazeTrackerOverride = tracker
        window = UITestSupport.host(reader)
        return reader
    }

    private func eyeButton(in reader: RSVPViewController) throws -> EyeTrackingToggleButton {
        try XCTUnwrap(reader.view.subviews.compactMap { $0 as? EyeTrackingToggleButton }.first)
    }

    private func playButton(in reader: RSVPViewController) throws -> UIButton {
        try XCTUnwrap(allSubviews(of: reader.view).compactMap { $0 as? UIButton }.first {
            $0.accessibilityLabel == L10n.string("Reader_rsvp_playAccessibilityLabel")
                || $0.accessibilityLabel == L10n.string("Reader_rsvp_pauseAccessibilityLabel")
        })
    }

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    func testLostFaceShowsUnavailableAndNeverPausesPlayback() throws {
        let reader = makeReader()
        let eye = try eyeButton(in: reader)
        eye.sendActions(for: .touchUpInside)
        try playButton(in: reader).sendActions(for: .touchUpInside)
        XCTAssertTrue(reader.isPlaying)

        tracker.onSample?(.faceLost)
        XCTAssertTrue(reader.isPlaying, "a dark room or dropped AR session must not interrupt reading")
        XCTAssertEqual(eye.trackingState, .unavailable)
        XCTAssertEqual(eye.tintColor, LunaColors.errorAccent)
        XCTAssertEqual(eye.accessibilityValue, L10n.string("Reader_rsvp_eyeTracking_unavailableAccessibilityValue"))

        tracker.onSample?(.point(reader.focalGazePoint))
        XCTAssertEqual(eye.trackingState, .active,
                       "a usable gaze point should restore the blue active state immediately")
        XCTAssertEqual(eye.tintColor, GlassStyle.readingAccent)
    }

    func testNormalPlayAfterAnAwaySampleDoesNotDisableTracking() throws {
        let reader = makeReader()
        let eye = try eyeButton(in: reader)
        eye.sendActions(for: .touchUpInside)

        // A stale/away sample before first play is not proof that gaze paused
        // the reader. The old heuristic incorrectly treated this as an override.
        tracker.onSample?(.offScreen)
        try playButton(in: reader).sendActions(for: .touchUpInside)

        XCTAssertTrue(reader.isPlaying)
        XCTAssertEqual(eye.trackingState, .active)
        XCTAssertTrue(ReaderSettings.eyeTrackingEnabled)
    }
}
