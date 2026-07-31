//
//  RSVPEyeTrackingTests.swift
//  LunaTests
//
//  The RSVP reader's eye-tracking toggle, driven end to end against a stub gaze
//  source: the three button states, the pause, the play-override, and the
//  read-aloud suppression. See claudedocs/eye-tracking.md.
//

import LunaDesignSystem
import LunaModels
import LunaReaderUI
import LunaStorage
import UIKit
import XCTest
@testable import Luna

/// Stands in for `ARFaceGazeTracker` — face tracking is never available on the
/// simulator, and the tests need to say exactly where the reader is looking.
private final class StubGazeTracker: GazeTracking {
    var onSample: ((GazeSample) -> Void)?
    var isRunning = false
    func start() { isRunning = true }
    func stop() { isRunning = false }
}

final class RSVPEyeTrackingTests: XCTestCase {

    private let content = UITestFixtures.sampleArticleContent(title: "Eye Tracking Fixture")
    private var item: ReadingListItem {
        ReadingListItem(seed: "eye-tracking", urlString: "https://example.com/eyes",
                        title: "Eye Tracking Fixture", dateAdded: UITestFixtures.baseDate,
                        state: .ready, wordCount: 480)
    }

    private var tracker = StubGazeTracker()
    private var window: UIWindow?

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
        GazeTrackingAvailability.supportOverride = true
        GazeTrackingPermission.statusOverride = .granted
        ReaderSettings.eyeTrackingEnabled = false
        ReaderSettings.rsvpMode = .words
        tracker = StubGazeTracker()
    }

    override func tearDown() {
        GazeTrackingAvailability.supportOverride = nil
        GazeTrackingPermission.statusOverride = nil
        ReaderSettings.eyeTrackingEnabled = false
        window = nil
        super.tearDown()
    }

    // MARK: - Harness

    private func makeReader(audioEnabled: Bool = false) -> RSVPViewController {
        let reader = RSVPViewController(item: item, content: content, audioEnabled: audioEnabled)
        reader.gazeTrackerOverride = tracker
        window = UITestSupport.host(reader)
        return reader
    }

    private func toggle(in reader: RSVPViewController) throws -> EyeTrackingToggleButton {
        try XCTUnwrap(
            reader.view.subviews.compactMap { $0 as? EyeTrackingToggleButton }.first,
            "the eye-tracking toggle should be installed where face tracking is available")
    }

    private func playButton(in reader: RSVPViewController) throws -> UIButton {
        try XCTUnwrap(
            allSubviews(of: reader.view).compactMap { $0 as? UIButton }.first {
                $0.accessibilityLabel == L10n.string("Play")
                    || $0.accessibilityLabel == L10n.string("Pause")
            })
    }

    private func allSubviews(of view: UIView) -> [UIView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    /// Feeds `sample` at display-ish cadence for up to `timeout` real seconds,
    /// stopping as soon as `until` is satisfied. The coordinator times gaze
    /// against the process clock, so this has to spend real time.
    @discardableResult
    private func feed(
        _ sample: GazeSample, timeout: TimeInterval = 3, until: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            tracker.onSample?(sample)
            if until() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        }
        return until()
    }

    // MARK: - Availability

    func testToggleIsAbsentWhereFaceTrackingCannotRun() {
        GazeTrackingAvailability.supportOverride = false
        let reader = makeReader()
        XCTAssertNil(
            reader.view.subviews.compactMap { $0 as? EyeTrackingToggleButton }
                .first(where: { !$0.isHidden }),
            "no TrueDepth camera (or an app extension) means no toggle at all")
    }

    func testToggleSitsInTheTopLeftClearOfTheReadingLayout() throws {
        let reader = makeReader()
        let button = try toggle(in: reader)
        LayoutAssertions.assertVisibleAndInBounds(button, in: reader.view)
        XCTAssertLessThan(button.frame.midX, reader.view.bounds.width / 3)
        XCTAssertLessThan(button.frame.midY, reader.view.bounds.height / 4)
    }

    // MARK: - The three states

    func testDefaultsToDisabledAndPersistsOnceEnabled() throws {
        let reader = makeReader()
        let button = try toggle(in: reader)
        XCTAssertEqual(button.trackingState, .disabled)
        XCTAssertFalse(tracker.isRunning, "nothing is watched until the user opts in")

        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(button.trackingState, .enabled)
        XCTAssertTrue(tracker.isRunning)
        XCTAssertTrue(ReaderSettings.eyeTrackingEnabled, "the setting survives a relaunch")

        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(button.trackingState, .disabled)
        XCTAssertFalse(tracker.isRunning)
        XCTAssertFalse(ReaderSettings.eyeTrackingEnabled)
    }

    func testBecomesActiveOnlyWhilePlaying() throws {
        let reader = makeReader()
        let button = try toggle(in: reader)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(button.trackingState, .enabled)

        try playButton(in: reader).sendActions(for: .touchUpInside)
        XCTAssertTrue(reader.isPlaying)
        XCTAssertEqual(button.trackingState, .active)

        try playButton(in: reader).sendActions(for: .touchUpInside)
        XCTAssertFalse(reader.isPlaying)
        XCTAssertEqual(button.trackingState, .enabled)
    }

    // MARK: - Pausing

    func testLookingAwayPausesPlayback() throws {
        let reader = makeReader()
        try toggle(in: reader).sendActions(for: .touchUpInside)
        try playButton(in: reader).sendActions(for: .touchUpInside)
        XCTAssertTrue(reader.isPlaying)

        XCTAssertTrue(feed(.offScreen, until: { !reader.isPlaying }),
                      "looking away from the screen should stop the reader")
    }

    func testGazeOnTheFocusedWordNeverPauses() throws {
        let reader = makeReader()
        try toggle(in: reader).sendActions(for: .touchUpInside)
        try playButton(in: reader).sendActions(for: .touchUpInside)

        feed(.point(reader.focalGazePoint), timeout: 1, until: { false })
        XCTAssertTrue(reader.isPlaying)
    }

    func testGazeInsideTheGenerousThresholdNeverPauses() throws {
        let reader = makeReader()
        try toggle(in: reader).sendActions(for: .touchUpInside)
        try playButton(in: reader).sendActions(for: .touchUpInside)

        // A glance at the surrounding context, well short of the focus radius.
        let focus = reader.focalGazePoint
        feed(.point(CGPoint(x: focus.x + 60, y: focus.y - 90)), timeout: 1, until: { false })
        XCTAssertTrue(reader.isPlaying)
    }

    func testDisabledTrackingNeverPauses() throws {
        let reader = makeReader()
        try playButton(in: reader).sendActions(for: .touchUpInside)
        XCTAssertTrue(reader.isPlaying)

        feed(.offScreen, timeout: 1, until: { false })
        XCTAssertTrue(reader.isPlaying, "the toggle is off; gaze has no say")
    }

    // MARK: - Play override

    func testPressingPlayWhileLookingAwayOverridesAndForceDisables() throws {
        let reader = makeReader()
        let button = try toggle(in: reader)
        button.sendActions(for: .touchUpInside)
        try playButton(in: reader).sendActions(for: .touchUpInside)
        XCTAssertTrue(feed(.offScreen, until: { !reader.isPlaying }))

        // Still looking away, the user insists.
        try playButton(in: reader).sendActions(for: .touchUpInside)
        XCTAssertTrue(reader.isPlaying)
        XCTAssertEqual(button.trackingState, .disabled)
        XCTAssertTrue(ReaderSettings.eyeTrackingEnabled,
                      "the override is transient — the stored preference is untouched")

        feed(.offScreen, timeout: 1, until: { false })
        XCTAssertTrue(reader.isPlaying, "the override outlives the glance that caused it")
    }

    func testManuallyPausingAfterAnOverrideRestoresTheSetting() throws {
        let reader = makeReader()
        let button = try toggle(in: reader)
        button.sendActions(for: .touchUpInside)
        try playButton(in: reader).sendActions(for: .touchUpInside)
        XCTAssertTrue(feed(.offScreen, until: { !reader.isPlaying }))
        try playButton(in: reader).sendActions(for: .touchUpInside)
        XCTAssertEqual(button.trackingState, .disabled)

        try playButton(in: reader).sendActions(for: .touchUpInside)
        XCTAssertFalse(reader.isPlaying)
        XCTAssertEqual(button.trackingState, .enabled,
                       "a deliberate pause reverts the force-disable")
    }

    // MARK: - Read-aloud

    func testReadAloudSuppressesTheToggleAndReturnsItAfterwards() throws {
        let reader = makeReader()
        let button = try toggle(in: reader)
        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(button.trackingState, .enabled)

        reader.configureForReuse(item: item, content: content, audioEnabled: true)
        reader.view.layoutIfNeeded()
        XCTAssertEqual(button.trackingState, .disabled)
        XCTAssertFalse(tracker.isRunning, "the camera stops when speech takes over pacing")
        XCTAssertFalse(button.isEnabled, "a tap here could only change something invisible")

        reader.configureForReuse(item: item, content: content, audioEnabled: false)
        reader.view.layoutIfNeeded()
        XCTAssertEqual(button.trackingState, .enabled,
                       "turning read-aloud off restores what the user had set")
        XCTAssertTrue(button.isEnabled)
    }

    // MARK: - Camera lifetime

    func testCameraStopsWhenTheReaderLeavesTheScreen() throws {
        let reader = makeReader()
        try toggle(in: reader).sendActions(for: .touchUpInside)
        XCTAssertTrue(tracker.isRunning)

        reader.beginAppearanceTransition(false, animated: false)
        reader.endAppearanceTransition()
        XCTAssertFalse(tracker.isRunning, "no camera behind a reader nobody is looking at")
    }
}
