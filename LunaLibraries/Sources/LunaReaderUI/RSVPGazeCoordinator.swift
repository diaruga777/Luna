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
final class RSVPGazeCoordinator {

    weak var delegate: RSVPGazeCoordinatorDelegate?

    private(set) var state: EyeTrackingState
    private var monitor = GazeAttentionMonitor()
    private var calibration = GazeCalibration()
    /// Set only for the pause request emitted by this coordinator. It is
    /// consumed by the next *manual* play press (the override), by the gaze
    /// settling back on the word (the auto-resume), or by anything that tears
    /// the camera down (leaving the reader, backgrounding). While set it is
    /// also the ONE reason the camera may run without playback — seeking the
    /// eyes' return, for as long as the reader stays here. There is
    /// deliberately no timeout: only a user action ends the hunt.
    private var awaitingManualResumeAfterGazePause = false {
        didSet {
            guard oldValue != awaitingManualResumeAfterGazePause else { return }
            syncTracker()
        }
    }
    /// When the gaze first settled back inside the focus radius after a
    /// gaze-caused pause. Once the return has lasted `resumeDwell`, playback
    /// resumes by itself — the pause this coordinator caused is also its to
    /// undo. The dwell keeps a saccade passing through the word from
    /// flapping playback.
    private var focusReturnStart: TimeInterval?
    private static let resumeDwell: TimeInterval = 0.4
    private let tracker: GazeTracking
    /// The view the focal point is expressed in, used to convert gaze samples
    /// out of screen space.
    private weak var referenceView: UIView?

    /// Whether the reader is on screen and in the foreground. The camera runs
    /// only while it is.
    private var isVisible = false {
        didSet { syncTracker() }
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
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.isAvailable = GazeTrackingAvailability.isSupported
        self.tracker = tracker ?? ARFaceGazeTracker()
        self.now = now
        self.state = EyeTrackingState(userEnabled: ReaderSettings.eyeTrackingEnabled)
        self.tracker.onSample = { [weak self] sample in self?.handle(sample) }
    }

    deinit { tracker.stop() }

    var displayState: EyeTrackingDisplayState { state.displayState }
    var isToggleInteractive: Bool { state.isToggleInteractive }

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
            awaitingManualResumeAfterGazePause = false
            // The eyes just left the play button — the strongest ground truth
            // this feature ever gets. Every playback start re-anchors the
            // calibration there (the previous offset stays in force while the
            // new anchor collects).
            calibration.beginWarmup()
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

    func setVisible(_ visible: Bool) { isVisible = visible }

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
        awaitingManualResumeAfterGazePause = false
        guard state.playOverridden else { return }
        state.playbackStoppedDeliberately()
        publish()
    }

    // MARK: - The toggle

    /// Handles a tap. Turning ON for the first time is the ONE moment the
    /// camera permission prompt appears; a refusal leaves the toggle off and
    /// explains where to change it.
    func toggle(presenting presenter: UIViewController) {
        guard state.isToggleInteractive else { return }
        guard state.toggleIntent == .turnOn else {
            state.applyToggle()
            persist()
            publish()
            return
        }
        GazeTrackingPermission.request { [weak self] status in
            guard let self else { return }
            guard status == .granted else {
                self.presentPermissionDenied(from: presenter)
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

    private func handle(_ sample: GazeSample) {
        guard state.isWatching, let view = referenceView, let delegate else { return }
        let focus = delegate.gazeCoordinatorFocalPoint(self)
        // A missing face is an explicit lack of signal, not evidence that the
        // reader looked away. In dim light and during ARKit relocalisation we
        // choose the harmless failure mode: do not interrupt reading.
        if case .faceLost = sample {
            if !state.gazeUnavailable {
                state.gazeUnavailable = true
                publish()
            }
            monitor.clear()
            return
        }
        if state.gazeUnavailable {
            state.gazeUnavailable = false
            publish()
        }

        // Judge every point against the CALIBRATED estimate: ARKit's raw gaze
        // carries a per-user bias easily larger than the focus radius, which
        // is exactly the "pauses every time while I'm reading" failure.
        // Off-screen (no plane intersection) needs no calibration and is fed
        // through as-is.
        let assessed: GazeSample
        switch converted(sample, in: view) {
        case .faceLost:
            return
        case .offScreen:
            assessed = .offScreen
        case .point(let point):
            let residual = CGVector(dx: point.x - focus.x, dy: point.y - focus.y)
            // Only playback vouches for where the eyes are; paused samples
            // must never anchor the offset.
            if state.isPlaying { calibration.ingest(residual) }
            guard let offset = calibration.offset else {
                // No baseline yet: the first moments of the first playback are
                // spent learning the estimator's bias, not judging the reader.
                return
            }
            let calibrated = CGPoint(x: point.x - offset.dx, y: point.y - offset.dy)
            let distance = hypot(calibrated.x - focus.x, calibrated.y - focus.y)
            if state.isPlaying, distance <= monitor.policy.focusRadius {
                calibration.recentre(towards: residual)
            }
            assessed = isOnDisplay(calibrated, in: view) ? .point(calibrated) : .offScreen
        }
        let now = self.now()
        let trippedThreshold = monitor.update(sample: assessed, focus: focus, at: now)

        // A pause this coordinator caused undoes itself: once the eyes have
        // settled back on the word for `resumeDwell`, play again. The dwell
        // keeps a saccade passing across the word from flapping playback.
        if awaitingManualResumeAfterGazePause, !state.isPlaying {
            if monitor.isAway {
                focusReturnStart = nil
            } else if let start = focusReturnStart {
                if now - start >= Self.resumeDwell {
                    focusReturnStart = nil
                    awaitingManualResumeAfterGazePause = false
                    delegate.gazeCoordinatorRequestsResume(self)
                }
            } else {
                focusReturnStart = now
            }
            return
        }

        guard trippedThreshold, state.isPlaying else { return }
        awaitingManualResumeAfterGazePause = true
        delegate.gazeCoordinatorRequestsPause(self)
    }

    /// Whether a calibrated point (in `view`'s coordinates) still lands on the
    /// physical display. The tracker no longer decides this — it can't, since
    /// only the calibrated point says where the reader is actually looking.
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

    /// The camera lifetime is AGGRESSIVE: it runs exactly while the feature is
    /// watching a PLAYING reader on screen — or, the one exception, while a
    /// gaze-caused pause is seeking the eyes' return, because that is the only
    /// way "look back to resume" can work. Merely opening the reader, toggling
    /// the feature on, or pausing deliberately never lights the camera, and
    /// the stop branch below ends an abandoned hunt for good.
    private func syncTracker() {
        let shouldRun = isAvailable && isVisible && state.isWatching
            && GazeTrackingPermission.status == .granted
            && (state.isPlaying || awaitingManualResumeAfterGazePause)
        guard shouldRun != tracker.isRunning else { return }
        if shouldRun {
            monitor.resetAllowance()
            // A fresh session is a fresh posture: forget the old bias and
            // collect a new anchor as soon as playback vouches for the gaze.
            calibration.reset()
            calibration.beginWarmup()
            tracker.start()
        } else {
            tracker.stop()
            monitor.clear()
            calibration.reset()
            // Whatever darkened the camera also ends the resume hunt: coming
            // back to the reader must not relight it — only a play press does.
            awaitingManualResumeAfterGazePause = false
            focusReturnStart = nil
        }
    }
}
