//
//  RSVPEyeTrackingReliabilityTests.swift
//  LunaTests
//
//  Regression coverage for confidence handling and the manual-resume latch.
//

import LunaDesignSystem
import LunaModels
import LunaStorage
import UIKit
import XCTest
@testable import Luna
@testable import LunaGaze
@testable import LunaReaderUI

private final class ReliabilityGazeTracker: GazeTracking {
    weak var delegate: GazeTrackingDelegate?
    var isRunning = false
    var starts = 0
    var stops = 0
    func start() { starts += 1; isRunning = true }
    func stop() { if isRunning { stops += 1 }; isRunning = false }

    /// Reports a sample the way a live camera frame does.
    func produce(_ sample: GazeSample) {
        delegate?.gazeTracker(self, didProduce: sample)
    }
}

final class RSVPEyeTrackingReliabilityTests: XCTestCase {

    private var tracker = ReliabilityGazeTracker()
    private var window: UIWindow?
    private var clock: TimeInterval = 100
    private let content = UITestFixtures.sampleArticleContent(title: "Gaze Reliability Fixture")
    private var item: SavedItem {
        SavedItem(seed: "gaze-reliability", urlString: "https://example.com/gaze",
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
        clock = 100
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
        reader.gazeClockOverride = { [unowned self] in self.clock }
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

    func testBriefLostFaceShowsUnavailableWithoutPausingPlayback() throws {
        let reader = makeReader()
        let eye = try eyeButton(in: reader)
        eye.sendActions(for: .touchUpInside)
        try playButton(in: reader).sendActions(for: .touchUpInside)
        XCTAssertTrue(reader.isPlaying)

        tracker.produce(.faceLost)
        XCTAssertTrue(reader.isPlaying, "a dark room or dropped AR session must not interrupt reading")
        XCTAssertEqual(eye.trackingState, .unavailable)
        XCTAssertEqual(eye.tintColor, LunaColors.errorAccent)
        XCTAssertEqual(eye.accessibilityValue, L10n.string("Reader_rsvp_eyeTracking_unavailableAccessibilityValue"))

        for _ in 0..<20 {
            tracker.produce(.point(reader.focalGazePoint))
            clock += 0.02
        }
        XCTAssertEqual(eye.trackingState, .active,
                       "stable acquisition restores the active state")
        XCTAssertEqual(eye.tintColor, GlassStyle.readingAccent)
    }

    func testNormalPlayAfterAnAwaySampleDoesNotDisableTracking() throws {
        let reader = makeReader()
        let eye = try eyeButton(in: reader)
        eye.sendActions(for: .touchUpInside)

        // A stale/away sample before first play is not proof that gaze paused
        // the reader. The old heuristic incorrectly treated this as an override.
        tracker.produce(.offScreen)
        try playButton(in: reader).sendActions(for: .touchUpInside)

        XCTAssertTrue(reader.isPlaying)
        XCTAssertEqual(eye.trackingState, .active)
        XCTAssertTrue(ReaderSettings.eyeTrackingEnabled)
    }
}


private final class AttentionDelegate: RSVPGazeCoordinatorDelegate {
    var pauses = 0
    var resumes = 0
    let focus = CGPoint(x: 195, y: 400)
    func gazeCoordinatorRequestsPause(_ coordinator: RSVPGazeCoordinator) {
        pauses += 1
        coordinator.setPlaying(false)
    }
    func gazeCoordinatorRequestsResume(_ coordinator: RSVPGazeCoordinator) {
        resumes += 1
        coordinator.setPlaying(true)
    }
    func gazeCoordinatorDidChangeDisplayState(_ coordinator: RSVPGazeCoordinator) {}
    func gazeCoordinatorFocalPoint(_ coordinator: RSVPGazeCoordinator) -> CGPoint { focus }
}

final class RSVPAttentionLifecycleTests: XCTestCase {
    private var tracker: ReliabilityGazeTracker!
    private var coordinator: RSVPGazeCoordinator!
    private var delegate: AttentionDelegate!
    private var view: UIView!
    private var clock: TimeInterval = 100
    private var permissionCompletion: ((GazeTrackingPermission.Status) -> Void)?

    override func setUp() {
        super.setUp()
        GazeTrackingAvailability.supportOverride = true
        GazeTrackingPermission.statusOverride = .granted
        ReaderSettings.eyeTrackingEnabled = true
        clock = 100
        tracker = ReliabilityGazeTracker()
        delegate = AttentionDelegate()
        view = UIView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        coordinator = RSVPGazeCoordinator(tracker: tracker, now: { [unowned self] in self.clock },
            requestPermission: { [unowned self] in self.permissionCompletion = $0 })
        coordinator.delegate = delegate
        coordinator.attach(to: view)
        coordinator.setVisible(true)
    }

    override func tearDown() {
        coordinator.setVisible(false)
        coordinator = nil
        GazeTrackingAvailability.supportOverride = nil
        GazeTrackingPermission.statusOverride = nil
        ReaderSettings.eyeTrackingEnabled = false
        permissionCompletion = nil
        super.tearDown()
    }

    private func feed(_ sample: GazeSample, for duration: TimeInterval) {
        let deadline = clock + duration
        while clock < deadline {
            tracker.produce(sample)
            clock += 0.02
        }
    }

    private func acquire() {
        coordinator.setPlaying(true)
        feed(.point(delegate.focus), for: 0.4)
        XCTAssertEqual(delegate.pauses, 0)
    }

    func testFaceLossPausesQuicklyAndStableReturnResumesWithoutCameraChurn() {
        acquire()
        feed(.faceLost, for: 0.36)
        XCTAssertEqual(delegate.pauses, 1)
        XCTAssertTrue(tracker.isRunning)
        feed(.point(delegate.focus), for: 0.3)
        XCTAssertEqual(delegate.resumes, 1)
        XCTAssertEqual(tracker.starts, 1)
        XCTAssertEqual(tracker.stops, 0)
        feed(.offScreen, for: 0.24)
        XCTAssertEqual(delegate.pauses, 2, "automatic resume preserves the baseline and attention checks")
    }

    func testBriefBlinkDoesNotPauseOrResumeFromClosedEyes() {
        acquire()
        feed(.faceLost, for: 0.12)
        feed(.point(delegate.focus), for: 0.1)
        XCTAssertEqual(delegate.pauses, 0)
        feed(.offScreen, for: 0.24)
        let frame = GazeFrame(sample: .point(delegate.focus), blinkLeft: 0.9,
                              blinkRight: 0.9, isFaceTracked: true)
        for _ in 0..<30 {
            coordinator.gazeTracker(tracker, didProduce: frame)
            clock += 0.02
        }
        XCTAssertEqual(delegate.resumes, 0)
    }

    func testLostFaceBreaksReturnDwell() {
        acquire()
        feed(.offScreen, for: 0.24)
        feed(.point(delegate.focus), for: 0.18)
        feed(.faceLost, for: 0.06)
        feed(.point(delegate.focus), for: 0.18)
        XCTAssertEqual(delegate.resumes, 0)
        feed(.point(delegate.focus), for: 0.12)
        XCTAssertEqual(delegate.resumes, 1)
    }

    func testFrameGapBreaksReturnDwell() {
        acquire()
        feed(.offScreen, for: 0.24)
        feed(.point(delegate.focus), for: 0.18)
        clock += 1
        feed(.point(delegate.focus), for: 0.18)
        XCTAssertEqual(delegate.resumes, 0)
        feed(.point(delegate.focus), for: 0.12)
        XCTAssertEqual(delegate.resumes, 1)
    }

    func testStartupWithoutFramesPausesThenAcquiresWhilePaused() {
        coordinator.setPlaying(true)
        clock += 1.6
        coordinator.checkTrackingHealth()
        XCTAssertEqual(delegate.pauses, 1)
        XCTAssertEqual(coordinator.displayState, .unavailable)
        feed(.point(delegate.focus), for: 0.65)
        XCTAssertEqual(delegate.resumes, 1, "initial acquisition cannot deadlock behind a playback pause")
    }

    func testMissingFramesAfterAcquisitionPauseAndRecoverFailedTracker() {
        acquire()
        for _ in 0..<7 {
            clock += 0.1
            coordinator.checkTrackingHealth()
        }
        XCTAssertEqual(delegate.pauses, 1)
        tracker.isRunning = false
        clock += 2
        coordinator.checkTrackingHealth()
        XCTAssertEqual(tracker.starts, 2)
        feed(.point(delegate.focus), for: 0.3)
        XCTAssertEqual(delegate.resumes, 1)
    }

    func testUnstableStartupDoesNotCalibrateAwayAnExcursion() {
        coordinator.setPlaying(true)
        for n in 0..<100 {
            tracker.produce(.point(CGPoint(x: delegate.focus.x + (n.isMultiple(of: 2) ? 400 : -400), y: 400)))
            clock += 0.02
        }
        XCTAssertEqual(delegate.pauses, 1)
        XCTAssertEqual(delegate.resumes, 0)
        feed(.point(delegate.focus), for: 0.65)
        XCTAssertEqual(delegate.resumes, 1)
    }

    func testSlowStartupDriftDoesNotFormAStableCluster() {
        coordinator.setPlaying(true)
        for n in 0..<100 {
            tracker.produce(.point(CGPoint(x: 100 + n * 15, y: 400)))
            clock += 0.02
        }
        XCTAssertEqual(delegate.pauses, 1)
        XCTAssertEqual(delegate.resumes, 0)
    }

    func testPartialAcquisitionCannotBridgeAMissingFrameGap() {
        coordinator.setPlaying(true)
        feed(.point(delegate.focus), for: 0.14)
        clock += 1
        feed(.point(delegate.focus), for: 0.14)
        clock += 0.5
        coordinator.checkTrackingHealth()
        XCTAssertEqual(delegate.pauses, 1, "neither partial fixation was long enough to acquire attention")
        feed(.point(delegate.focus), for: 0.65)
        XCTAssertEqual(delegate.resumes, 1)
    }

    func testDisablingTrackingEndsHuntAndHiddenForegroundCannotRestartCamera() {
        acquire()
        feed(.offScreen, for: 0.24)
        coordinator.toggle(presenting: UIViewController())
        XCTAssertFalse(ReaderSettings.eyeTrackingEnabled)
        XCTAssertFalse(tracker.isRunning)
        feed(.point(delegate.focus), for: 0.5)
        XCTAssertEqual(delegate.resumes, 0)
        coordinator.setVisible(false)
        coordinator.setActive(false)
        coordinator.setActive(true)
        XCTAssertFalse(tracker.isRunning)
    }

    func testExplicitPauseEndsReturnHunt() {
        acquire()
        feed(.offScreen, for: 0.24)
        coordinator.notePlaybackStoppedDeliberately()
        XCTAssertFalse(tracker.isRunning)
        feed(.point(delegate.focus), for: 1)
        XCTAssertEqual(delegate.resumes, 0)
    }

    func testBackgroundAudioAndLeavingEndReturnHunt() {
        for stop in [ { self.coordinator.setActive(false) },
                      { self.coordinator.setAudioPlaybackOn(true) },
                      { self.coordinator.setVisible(false) } ] {
            coordinator.setActive(true)
            coordinator.setAudioPlaybackOn(false)
            coordinator.setVisible(true)
            coordinator.setPlaying(true)
            feed(.point(delegate.focus), for: 0.4)
            feed(.offScreen, for: 0.24)
            stop()
            XCTAssertFalse(tracker.isRunning)
            feed(.point(delegate.focus), for: 0.5)
            XCTAssertEqual(delegate.resumes, 0)
        }
    }

    private func requestFirstPermission() {
        ReaderSettings.eyeTrackingEnabled = false
        coordinator.setVisible(false)
        coordinator = RSVPGazeCoordinator(tracker: tracker, now: { [unowned self] in self.clock },
            requestPermission: { [unowned self] in self.permissionCompletion = $0 })
        coordinator.delegate = delegate
        coordinator.attach(to: view)
        coordinator.setVisible(true)
        GazeTrackingPermission.statusOverride = .undetermined
        coordinator.setPlaying(true)
        coordinator.toggle(presenting: UIViewController())
        XCTAssertEqual(delegate.pauses, 1, "pause before the asynchronous system prompt")
        XCTAssertFalse(tracker.isRunning)
        XCTAssertFalse(coordinator.isToggleInteractive)
    }

    func testPendingPermissionPausesAndGrantStaysPaused() {
        requestFirstPermission()
        GazeTrackingPermission.statusOverride = .granted
        permissionCompletion?(.granted)
        XCTAssertTrue(ReaderSettings.eyeTrackingEnabled)
        XCTAssertFalse(tracker.isRunning)
        XCTAssertEqual(delegate.resumes, 0)
        XCTAssertTrue(coordinator.isToggleInteractive)
        coordinator.setPlaying(true)
        XCTAssertTrue(tracker.isRunning)
    }

    func testDeniedPermissionKeepsTrackingOff() {
        requestFirstPermission()
        permissionCompletion?(.denied)
        XCTAssertFalse(ReaderSettings.eyeTrackingEnabled)
        XCTAssertFalse(tracker.isRunning)
        XCTAssertEqual(delegate.resumes, 0)
    }

    func testDelayedPermissionCannotEnableAfterLeavingOrManualPlaybackChange() {
        requestFirstPermission()
        coordinator.setVisible(false)
        GazeTrackingPermission.statusOverride = .granted
        permissionCompletion?(.granted)
        XCTAssertFalse(ReaderSettings.eyeTrackingEnabled)
        XCTAssertFalse(tracker.isRunning)
        coordinator.setVisible(true)
        coordinator.toggle(presenting: UIViewController())
        coordinator.notePlaybackStoppedDeliberately()
        permissionCompletion?(.granted)
        XCTAssertFalse(ReaderSettings.eyeTrackingEnabled)
    }
}
