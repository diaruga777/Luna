//
//  RSVPGazeCoordinator.swift
//  LunaReaderUI
//

import LunaDesignSystem
import LunaModels
import UIKit

protocol RSVPGazeCoordinatorDelegate: AnyObject {
    /// The reader has been looking away from the focal word long enough —
    /// stop playback. Only ever sent while playback is running and silent.
    func gazeCoordinatorRequestsPause(_ coordinator: RSVPGazeCoordinator)
    /// The eyes settled back on the focal word after a pause THIS coordinator
    /// caused — start playback again. Never sent for deliberate pauses.
    func gazeCoordinatorRequestsResume(_ coordinator: RSVPGazeCoordinator)
    /// The toggle's appearance needs refreshing.
    func gazeCoordinatorDidChangeDisplayState(_ coordinator: RSVPGazeCoordinator)
    /// Where the focal word currently sits, in the reader view's coordinates.
    func gazeCoordinatorFocalPoint(_ coordinator: RSVPGazeCoordinator) -> CGPoint
}

/// Owns the RSVP reader's eye-tracking feature: the durable toggle state, the
/// camera session's lifetime, and the away-from-the-word timer.
///
/// The reader itself only tells it about things the reader knows — playback
/// started/stopped, read-aloud turned on, the view appeared — and asks it one
/// question back: is the reader looking away right now (so a play press can be
/// recognised as an override). See `claudedocs/eye-tracking.md`.
final class RSVPGazeCoordinator: GazeTrackingDelegate {

    weak var delegate: RSVPGazeCoordinatorDelegate?

    private(set) var state: EyeTrackingState
    private var monitor = GazeAttentionMonitor()
    private var calibration = GazeCalibration(warmupSampleCount: 12, recentreRate: 0)
    /// Set only for the pause request emitted by this coordinator. It is
    /// consumed by the next *manual* play press (the override), by the gaze
    /// settling back on the word (the auto-resume), or by anything that tears
    /// the camera down (leaving the reader, backgrounding). While set it is
    /// also the ONE reason the camera may run without playback — seeking the
    /// eyes' return, for as long as the reader stays here. There is
    /// deliberately no timeout: only a user action ends the hunt.
    private var awaitingManualResumeAfterGazePause = false
    private var automaticallyResuming = false
    private var permissionRequestID: UUID?
    private let requestPermission: (@escaping (GazeTrackingPermission.Status) -> Void) -> Void
    private var watchdog: Timer?
    private var sessionStartedAt: TimeInterval?
    private var lastSampleAt: TimeInterval?
    private var lastRecoveryAt: TimeInterval?
    private var acquiredAttention = false
    private var acquisitionStart: TimeInterval?
    private var acquisitionPoint: CGPoint?
    private var isActive = true
    /// When the gaze first settled back inside the focus radius after a
    /// gaze-caused pause. Once the return has lasted `resumeDwell`, playback
    /// resumes by itself — the pause this coordinator caused is also its to
    /// undo. The dwell keeps a saccade passing through the word from
    /// flapping playback.
    private var focusReturnStart: TimeInterval?
    private static let resumeDwell: TimeInterval = 0.25
    private let tracker: GazeTracking
    /// The view the focal point is expressed in, used to convert gaze samples
    /// out of screen space.
    private weak var referenceView: UIView?

    /// Whether this reader is on screen. App activity is tracked separately.
    private var isVisible = false {
        didSet { publish() }
    }

    /// Whether face tracking exists at all here. Fixed for the process, so the
    /// toggle can simply be hidden where it could never work (no TrueDepth
    /// camera; inside an app extension).
    let isAvailable: Bool

    /// Where "now" comes from. Every duration this coordinator measures — the
    /// away threshold, the resume dwell — is a difference between two readings
    /// of this, so a test can hand it a clock it advances itself instead of
    /// spending the seconds. Production reads the process clock.
    private let now: () -> TimeInterval

    init(tracker: GazeTracking? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         requestPermission: @escaping (@escaping (GazeTrackingPermission.Status) -> Void) -> Void = GazeTrackingPermission.request) {
        self.isAvailable = GazeTrackingAvailability.isSupported
        self.tracker = tracker ?? ARFaceGazeTracker()
        self.now = now
        self.requestPermission = requestPermission
        self.state = EyeTrackingState(userEnabled: ReaderSettings.eyeTrackingEnabled)
        self.tracker.delegate = self
    }

    deinit { watchdog?.invalidate(); tracker.stop() }

    var displayState: EyeTrackingDisplayState { state.displayState }
    var isToggleInteractive: Bool { state.isToggleInteractive && permissionRequestID == nil }

    /// The legacy controller seam asks whether a play press is an override.
    /// The latch is authoritative: a stale away sample alone must not make a
    /// normal play press disable tracking.
    var isLookingAway: Bool {
        state.isWatching && (awaitingManualResumeAfterGazePause || monitor.isAway)
    }

    func attach(to view: UIView) { referenceView = view }

    // MARK: - Inputs from the reader

    func setPlaying(_ playing: Bool) {
        guard state.isPlaying != playing else { return }
        state.isPlaying = playing
        focusReturnStart = nil
        if playing {
            if !automaticallyResuming { permissionRequestID = nil }
            awaitingManualResumeAfterGazePause = false
        }
        // Every excursion is judged against the playback it might interrupt;
        // starting fresh means a glance taken while paused never counts.
        monitor.resetAllowance()
        publish()
    }

    func setAudioPlaybackOn(_ on: Bool) {
        guard state.audioPlaybackOn != on else { return }
        state.audioPlaybackOn = on
        publish()
    }

    func setVisible(_ visible: Bool) {
        if !visible { permissionRequestID = nil }
        isVisible = visible
    }

    func setActive(_ active: Bool) {
        isActive = active
        publish()
    }

    /// The focal word jumped (scrub, skip, sub-mode switch): the reader's eyes
    /// were legitimately elsewhere while they aimed at the control. Residuals
    /// collected against the old focal position are stale, but an established
    /// offset is a physical property of the estimator and survives untouched.
    func focalPositionDidJump() {
        monitor.resetAllowance()
        calibration.invalidateWarmup()
        focusReturnStart = nil
    }

    /// The controller invokes this from a user play press. It has an effect
    /// only if this coordinator actually caused the preceding pause.
    func notePlayOverride() {
        guard awaitingManualResumeAfterGazePause else { return }
        awaitingManualResumeAfterGazePause = false
        guard state.isWatching else { return }
        state.overrideWithPlay()
        publish()
    }

    /// Playback stopped by any route other than gaze. Reverts a play-override
    /// to whatever the user's own setting was.
    func notePlaybackStoppedDeliberately() {
        permissionRequestID = nil
        awaitingManualResumeAfterGazePause = false
        syncTracker()
        guard state.playOverridden else { return }
        state.playbackStoppedDeliberately()
        publish()
    }

    // MARK: - The toggle

    /// The first opt-in pauses before the system permission prompt. A response
    /// may enable the preference, but never starts playback by itself.
    func toggle(presenting presenter: UIViewController) {
        guard isAvailable, isToggleInteractive else { return }
        guard state.toggleIntent == .turnOn else {
            state.applyToggle()
            persist()
            publish()
            return
        }
        let id = UUID()
        permissionRequestID = id
        // The system prompt hides the word. Pause before requesting access;
        // permission is not a gaze pause and must never arm auto-resume.
        if GazeTrackingPermission.status == .undetermined, state.isPlaying {
            delegate?.gazeCoordinatorRequestsPause(self)
        }
        publish()
        requestPermission { [weak self, weak presenter] status in
            guard let self, self.permissionRequestID == id else { return }
            self.permissionRequestID = nil
            guard self.isVisible, self.state.isToggleInteractive,
                  self.state.toggleIntent == .turnOn else { self.publish(); return }
            guard status == .granted else {
                self.publish()
                if let presenter, presenter.viewIfLoaded?.window != nil {
                    self.presentPermissionDenied(from: presenter)
                }
                return
            }
            self.state.applyToggle()
            self.monitor.resetAllowance()
            self.persist()
            self.publish()
        }
    }

    private func presentPermissionDenied(from presenter: UIViewController) {
        let alert = UIAlertController(
            title: L10n.string("Reader_rsvp_gaze_cameraAccessDeniedTitle"),
            message: L10n.string("Reader_rsvp_gaze_cameraAccessDeniedMessage"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_notNow"), style: .cancel))
        if let settings = URL(string: UIApplication.openSettingsURLString) {
            alert.addAction(UIAlertAction(
                title: L10n.string("Common_openSettings"), style: .default,
                handler: { _ in UIApplication.shared.open(settings) }))
        }
        presenter.present(alert, animated: true)
    }

    // MARK: - Gaze

    var prefersGazeFrames: Bool { true }

    func gazeTracker(_ tracker: GazeTracking, didProduce frame: GazeFrame) {
        let usable = frame.isFaceTracked && frame.blinkLeft < 0.65 && frame.blinkRight < 0.65
        gazeTracker(tracker, didProduce: usable ? frame.sample : .faceLost)
    }

    func gazeTracker(_ tracker: GazeTracking, didProduce sample: GazeSample) {
        guard cameraWanted,
              let view = referenceView, let delegate else { return }
        let timestamp = now()
        let gap = lastSampleAt.map { timestamp - $0 }
        lastSampleAt = timestamp
        if let gap, gap > 0.15 {
            focusReturnStart = nil
            if !acquiredAttention { resetAcquisition() }
        }
        let focus = delegate.gazeCoordinatorFocalPoint(self)
        var assessed = converted(sample, in: view)
        if case .point(let point) = assessed {
            guard point.x.isFinite, point.y.isFinite else {
                handleUnavailable(at: timestamp, focus: focus)
                return
            }
            // Establish a short, stable fixation, including while a startup
            // pause waits for its first usable face. Never learn from movement
            // or keep adapting the baseline to a slow glance away.
            if !acquiredAttention {
                if let previous = acquisitionPoint,
                   hypot(point.x - previous.x, point.y - previous.y) > 100 {
                    resetAcquisition()
                }
                if acquisitionStart == nil { acquisitionStart = timestamp }
                if acquisitionPoint == nil { acquisitionPoint = point }
                calibration.ingest(CGVector(dx: point.x - focus.x, dy: point.y - focus.y))
                if calibration.offset != nil,
                   timestamp - (acquisitionStart ?? timestamp) >= 0.2 {
                    acquiredAttention = true
                    monitor.clear()
                } else {
                    checkAcquisitionTimeout(at: timestamp, focus: focus)
                    return
                }
            }
            let calibrated = calibration.calibrated(point)
            assessed = isOnDisplay(calibrated, in: view) ? .point(calibrated) : .offScreen
        } else {
            if !acquiredAttention { resetAcquisition() }
        }
        if case .faceLost = assessed {
            handleUnavailable(at: timestamp, focus: focus)
            return
        }
        setUnavailable(false)
        assess(assessed, focus: focus, at: timestamp)
    }

    private func resetAcquisition() {
        acquisitionStart = nil
        acquisitionPoint = nil
        calibration.reset()
        calibration.beginWarmup()
    }

    private func setUnavailable(_ unavailable: Bool) {
        guard state.gazeUnavailable != unavailable else { return }
        state.gazeUnavailable = unavailable
        delegate?.gazeCoordinatorDidChangeDisplayState(self)
    }

    private func handleUnavailable(at timestamp: TimeInterval, focus: CGPoint) {
        focusReturnStart = nil
        setUnavailable(true)
        if acquiredAttention {
            assess(.faceLost, focus: focus, at: timestamp)
        } else {
            checkAcquisitionTimeout(at: timestamp, focus: focus)
        }
    }

    private func checkAcquisitionTimeout(at timestamp: TimeInterval, focus: CGPoint) {
        setUnavailable(true)
        if timestamp - (sessionStartedAt ?? timestamp) >= 1.5 {
            requestAttentionPause()
        }
    }

    private func requestAttentionPause() {
        guard state.isPlaying, !awaitingManualResumeAfterGazePause else { return }
        awaitingManualResumeAfterGazePause = true
        delegate?.gazeCoordinatorRequestsPause(self)
    }

    private func assess(_ sample: GazeSample, focus: CGPoint, at timestamp: TimeInterval) {
        let threshold = monitor.update(sample: sample, focus: focus, at: timestamp)
        if awaitingManualResumeAfterGazePause, !state.isPlaying {
            if monitor.isAway || !acquiredAttention {
                focusReturnStart = nil
            } else if let start = focusReturnStart {
                if timestamp - start >= Self.resumeDwell {
                    // Keep the pause latch through the synchronous play callback.
                    // setPlaying(true) consumes it without ever stopping ARKit.
                    automaticallyResuming = true
                    delegate?.gazeCoordinatorRequestsResume(self)
                    automaticallyResuming = false
                    focusReturnStart = nil
                }
            } else {
                focusReturnStart = timestamp
            }
        } else if threshold {
            requestAttentionPause()
        }
    }

    /// Called by the timer even when ARKit stops delivering frames. Internal
    /// so tests can advance the same clock without sleeping.
    func checkTrackingHealth() {
        guard cameraWanted, let start = sessionStartedAt else { return }
        let timestamp = now()
        if timestamp - (lastSampleAt ?? start) > 0.2 {
            if !acquiredAttention { resetAcquisition() }
            if let delegate {
                handleUnavailable(at: timestamp, focus: delegate.gazeCoordinatorFocalPoint(self))
            }
        }
        // Recover a failed or silent session at a bounded rate. This does not
        // erase a known reading baseline or the automatic-pause latch.
        if !tracker.isRunning || timestamp - (lastSampleAt ?? start) > 2 {
            guard timestamp - (lastRecoveryAt ?? start) >= 2 else { return }
            lastRecoveryAt = timestamp
            lastSampleAt = timestamp
            tracker.stop()
            tracker.start()
        }
    }

    /// Whether a calibrated point (in `view`'s coordinates) still lands on the
    /// physical display. This decides it, not the tracker: only the calibrated
    /// point says where the reader is actually looking.
    private func isOnDisplay(_ point: CGPoint, in view: UIView) -> Bool {
        guard let window = view.window else { return true }
        let inWindow = view.convert(point, to: window)
        let onScreen = CGPoint(
            x: inWindow.x + window.frame.origin.x, y: inWindow.y + window.frame.origin.y)
        return GazeScreenProjection.isOnScreen(onScreen, screenSize: window.screen.bounds.size)
    }

    /// Moves a gaze point out of the tracker's portrait-fixed screen space and
    /// into the reader view's coordinates, in three steps: rotate for the
    /// interface orientation, subtract the window's own screen position (an
    /// iPad in Split View), then let UIKit walk the view hierarchy.
    private func converted(_ sample: GazeSample, in view: UIView) -> GazeSample {
        guard case .point(let point) = sample, let window = view.window else { return sample }
        let onScreen = GazeScreenProjection.orientedScreenPoint(
            fromPortraitPoint: point,
            portraitSize: window.screen.fixedCoordinateSpace.bounds.size,
            orientation: window.windowScene?.interfaceOrientation ?? .portrait)
        let inWindow = CGPoint(
            x: onScreen.x - window.frame.origin.x, y: onScreen.y - window.frame.origin.y)
        return .point(view.convert(inWindow, from: window))
    }

    // MARK: - Plumbing

    private func persist() {
        ReaderSettings.eyeTrackingEnabled = state.userEnabled
    }

    private func publish() {
        syncTracker()
        delegate?.gazeCoordinatorDidChangeDisplayState(self)
    }

    private var cameraWanted: Bool {
        isAvailable && isVisible && isActive && state.isWatching
            && permissionRequestID == nil && GazeTrackingPermission.status == .granted
            && (state.isPlaying || awaitingManualResumeAfterGazePause)
    }

    private func syncTracker() {
        if cameraWanted {
            guard watchdog == nil else { return }
            monitor.clear()
            acquiredAttention = false
            resetAcquisition()
            sessionStartedAt = now()
            lastSampleAt = nil
            lastRecoveryAt = nil
            tracker.start()
            let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.checkTrackingHealth()
            }
            watchdog = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            watchdog?.invalidate()
            watchdog = nil
            tracker.stop()
            monitor.clear()
            calibration.reset()
            acquiredAttention = false
            sessionStartedAt = nil
            lastSampleAt = nil
            awaitingManualResumeAfterGazePause = false
            focusReturnStart = nil
            state.gazeUnavailable = false
        }
    }
}
