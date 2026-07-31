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

    init(tracker: GazeTracking? = nil) {
        self.isAvailable = GazeTrackingAvailability.isSupported
        self.tracker = tracker ?? ARFaceGazeTracker()
        self.state = EyeTrackingState(userEnabled: ReaderSettings.eyeTrackingEnabled)
        self.tracker.onSample = { [weak self] sample in self?.handle(sample) }
    }

    deinit { tracker.stop() }

    var displayState: EyeTrackingDisplayState { state.displayState }
    var isToggleInteractive: Bool { state.isToggleInteractive }

    /// True while the most recent gaze estimate was off the focal word — the
    /// test a play press makes to decide whether it is an override.
    var isLookingAway: Bool { state.isWatching && monitor.isAway }

    func attach(to view: UIView) { referenceView = view }

    // MARK: - Inputs from the reader

    func setPlaying(_ playing: Bool) {
        guard state.isPlaying != playing else { return }
        state.isPlaying = playing
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
    /// were legitimately elsewhere while they aimed at the control.
    func focalPositionDidJump() { monitor.resetAllowance() }

    /// The user pressed play while looking away — an explicit override that
    /// keeps playback running and stands the feature down.
    func notePlayOverride() {
        guard state.isWatching else { return }
        state.overrideWithPlay()
        publish()
    }

    /// Playback stopped by any route other than gaze. Reverts a play-override
    /// to whatever the user's own setting was.
    func notePlaybackStoppedDeliberately() {
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
            title: L10n.string("Camera Access Needed"),
            message: L10n.string(
                "Luna tracks your eyes to pause playback automatically when you look away. Turn on camera access in Settings to use it."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Not Now"), style: .cancel))
        if let settings = URL(string: UIApplication.openSettingsURLString) {
            alert.addAction(UIAlertAction(
                title: L10n.string("Open Settings"), style: .default,
                handler: { _ in UIApplication.shared.open(settings) }))
        }
        presenter.present(alert, animated: true)
    }

    // MARK: - Gaze

    private func handle(_ sample: GazeSample) {
        guard state.isWatching, let view = referenceView, let delegate else { return }
        let focus = delegate.gazeCoordinatorFocalPoint(self)
        let converted = converted(sample, in: view)
        let trippedThreshold = monitor.update(
            sample: converted, focus: focus, at: ProcessInfo.processInfo.systemUptime)
        // Away-ness is tracked even while paused — that is what lets a play
        // press taken mid-glance be recognised as an override — but only a
        // running playback is ever interrupted.
        guard trippedThreshold, state.isPlaying else { return }
        delegate.gazeCoordinatorRequestsPause(self)
    }

    /// Moves a screen-space gaze point into the reader view's coordinates. The
    /// tracker reports in `UIScreen.fixedCoordinateSpace`, which stays
    /// portrait-origin, so UIKit absorbs any interface rotation here.
    private func converted(_ sample: GazeSample, in view: UIView) -> GazeSample {
        guard case .point(let point) = sample else { return sample }
        guard let screen = view.window?.screen else { return sample }
        return .point(view.convert(point, from: screen.fixedCoordinateSpace))
    }

    // MARK: - Plumbing

    private func persist() {
        ReaderSettings.eyeTrackingEnabled = state.userEnabled
    }

    private func publish() {
        syncTracker()
        delegate?.gazeCoordinatorDidChangeDisplayState(self)
    }

    /// The camera runs exactly while the feature is watching and the reader is
    /// on screen — never merely because the reader is open, and never once the
    /// toggle is off or read-aloud has taken over.
    private func syncTracker() {
        let shouldRun = isAvailable && isVisible && state.isWatching
            && GazeTrackingPermission.status == .granted
        guard shouldRun != tracker.isRunning else { return }
        if shouldRun {
            monitor.resetAllowance()
            tracker.start()
        } else {
            tracker.stop()
            monitor.clear()
        }
    }
}
