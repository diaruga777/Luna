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
                $0.accessibilityLabel == L10n.string("Reader_rsvp_playAccessibilityLabel")
                    || $0.accessibilityLabel == L10n.string("Reader_rsvp_pauseAccessibilityLabel")
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

    /// The toggle mirrors the deck's read-aloud circle: same diameter, same
    /// 12pt corner inset, opposite corner — so the pair reads as one row across
    /// the card's top edge.
    func testToggleSitsInTheTopLeadingCornerOppositeTheReadAloudCircle() throws {
        let reader = makeReader()
        let button = try toggle(in: reader)
        LayoutAssertions.assertVisibleAndInBounds(button, in: reader.view)
        XCTAssertEqual(button.frame.minX, 12, accuracy: 0.5)
        XCTAssertEqual(
            button.frame.minY, reader.view.safeAreaInsets.top + 12, accuracy: 0.5)
        XCTAssertEqual(
            button.frame.width, button.frame.height, accuracy: 0.5,
            "a capsule-cornered toggle is only a circle while it stays square")
        XCTAssertEqual(button.frame.width, EyeTrackingToggleButton.diameter, accuracy: 0.5)
    }

    /// Inside a card the host's chrome — an OPAQUE title header — stands over
    /// the top of the reader as a SIBLING ABOVE its view. A toggle placed level
    /// with the deck's own circles is therefore not merely crowded by that
    /// header, it is behind it, and the control vanishes from the speed reader.
    /// The reader's first usable line is `topContentInset` down.
    func testToggleClearsHostChromeStandingOverTheReader() throws {
        let reader = makeReader()
        let button = try toggle(in: reader)
        let headerHeight: CGFloat = 84

        reader.topContentInset = headerHeight
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()

        XCTAssertEqual(button.frame.minX, 12, accuracy: 0.5)
        XCTAssertEqual(
            button.frame.minY, reader.view.safeAreaInsets.top + headerHeight + 12,
            accuracy: 0.5,
            "the toggle must sit below the host chrome, not underneath it")
    }

    // MARK: - The three states

    func testDefaultsToDisabledAndPersistsOnceEnabled() throws {
        let reader = makeReader()
        let button = try toggle(in: reader)
        XCTAssertEqual(button.trackingState, .disabled)
        XCTAssertFalse(tracker.isRunning, "nothing is watched until the user opts in")

        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(button.trackingState, .enabled)
        XCTAssertFalse(tracker.isRunning,
                       "opting in must not light the camera — only playback does")
        XCTAssertTrue(ReaderSettings.eyeTrackingEnabled, "the setting survives a relaunch")

        button.sendActions(for: .touchUpInside)
        XCTAssertEqual(button.trackingState, .disabled)
        XCTAssertFalse(tracker.isRunning)
        XCTAssertFalse(ReaderSettings.eyeTrackingEnabled)
    }

    /// The camera lifetime is aggressive: playing lights it, a deliberate
    /// pause darkens it immediately.
    func testCameraRunsOnlyWhilePlaying() throws {
        let reader = makeReader()
        try toggle(in: reader).sendActions(for: .touchUpInside)
        XCTAssertFalse(tracker.isRunning)

        try playButton(in: reader).sendActions(for: .touchUpInside)
        XCTAssertTrue(reader.isPlaying)
        XCTAssertTrue(tracker.isRunning)

        try playButton(in: reader).sendActions(for: .touchUpInside)
        XCTAssertFalse(reader.isPlaying)
        XCTAssertFalse(tracker.isRunning,
                       "a deliberate pause must tear the camera down at once")
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

    // MARK: - Calibration

    /// THE regression test for "it always pauses after a second or two even
    /// though my eyes are locked on the word": ARKit's raw gaze carries a
    /// systematic per-user bias, easily beyond the focus radius. Warm-up must
    /// learn that bias from the first samples of playback and subtract it, so
    /// a fixated reader is never paused no matter how biased the estimator is.
    func testASystematicEstimatorBiasNeverPausesAFixatedReader() throws {
        let reader = makeReader()
        try toggle(in: reader).sendActions(for: .touchUpInside)
        try playButton(in: reader).sendActions(for: .touchUpInside)
        XCTAssertTrue(reader.isPlaying)

        // Every sample lands a fixed ~380pt from the word — raw, that is
        // "away" (worth ~1.4s of tolerance), and 4 seconds of it would have
        // paused the reader twice over.
        let focus = reader.focalGazePoint
        let biased = CGPoint(x: focus.x + 320, y: focus.y - 200)
        feed(.point(biased), timeout: 4, until: { !reader.isPlaying })
        XCTAssertTrue(reader.isPlaying,
                      "a constant bias is the estimator's error, not the reader's glance")
    }

    /// Calibration must remove the bias, not the feature: an excursion beyond
    /// the learned baseline still pauses.
    func testAGenuineLookAwayStillPausesAfterCalibration() throws {
        let reader = makeReader()
        try toggle(in: reader).sendActions(for: .touchUpInside)
        try playButton(in: reader).sendActions(for: .touchUpInside)

        let focus = reader.focalGazePoint
        let bias = CGVector(dx: 320, dy: -200)
        let reading = CGPoint(x: focus.x + bias.dx, y: focus.y + bias.dy)
        feed(.point(reading), timeout: 2.5, until: { false })
        XCTAssertTrue(reader.isPlaying, "still fixated — only the bias moved")

        // The same bias, plus a real 500pt excursion.
        let away = CGPoint(x: reading.x, y: reading.y + 500)
        XCTAssertTrue(feed(.point(away), timeout: 4, until: { !reader.isPlaying }),
                      "calibration must not swallow genuine excursions")
    }

    // MARK: - Auto-resume

    /// A pause caused by the gaze undoes itself: the camera keeps watching,
    /// and once the eyes settle back on the word playback resumes — with
    /// tracking still enabled, because nobody overrode anything.
    func testLookingBackAtTheWordResumesAGazePause() throws {
        let reader = makeReader()
        let button = try toggle(in: reader)
        button.sendActions(for: .touchUpInside)
        try playButton(in: reader).sendActions(for: .touchUpInside)

        let focus = reader.focalGazePoint
        let reading = CGPoint(x: focus.x + 320, y: focus.y - 200)
        feed(.point(reading), timeout: 2.5, until: { false })  // calibrates
        XCTAssertTrue(reader.isPlaying)

        let away = CGPoint(x: reading.x, y: reading.y + 600)
        XCTAssertTrue(feed(.point(away), until: { !reader.isPlaying }))
        XCTAssertTrue(tracker.isRunning,
                      "the camera keeps watching for the eyes to come back")

        XCTAssertTrue(feed(.point(reading), until: { reader.isPlaying }),
                      "settling back on the word should resume playback by itself")
        XCTAssertEqual(button.trackingState, .active, "an auto-resume is not an override")
    }

    /// The resume hunt has no timeout — but leaving the reader mid-hunt kills
    /// the camera, and coming back must NOT relight it: only a play press
    /// does, and that press is an ordinary one (tracking stays enabled).
    func testLeavingDuringAGazePauseEndsTheHuntUntilTheNextPlay() throws {
        let reader = makeReader()
        let button = try toggle(in: reader)
        button.sendActions(for: .touchUpInside)
        try playButton(in: reader).sendActions(for: .touchUpInside)
        XCTAssertTrue(feed(.offScreen, until: { !reader.isPlaying }))
        XCTAssertTrue(tracker.isRunning, "the hunt for the returning gaze is on")

        reader.beginAppearanceTransition(false, animated: false)
        reader.endAppearanceTransition()
        XCTAssertFalse(tracker.isRunning, "leaving the reader kills the camera outright")

        reader.beginAppearanceTransition(true, animated: false)
        reader.endAppearanceTransition()
        XCTAssertFalse(tracker.isRunning,
                       "coming back must not relight the camera by itself")

        try playButton(in: reader).sendActions(for: .touchUpInside)
        XCTAssertTrue(reader.isPlaying)
        XCTAssertEqual(button.trackingState, .active,
                       "play after an abandoned hunt is not an override — tracking stays on")
        XCTAssertTrue(tracker.isRunning, "playback lights the camera again")
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
        try playButton(in: reader).sendActions(for: .touchUpInside)
        XCTAssertTrue(tracker.isRunning)

        reader.beginAppearanceTransition(false, animated: false)
        reader.endAppearanceTransition()
        XCTAssertFalse(tracker.isRunning, "no camera behind a reader nobody is looking at")
    }
}
