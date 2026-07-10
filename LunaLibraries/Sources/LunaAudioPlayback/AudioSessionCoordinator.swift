//
//  AudioSessionCoordinator.swift
//  LunaAudioPlayback
//

import AVFoundation

/// The new-path `AVAudioSession` choke point for `AudioPlaybackCenter` —
/// `.playback` + `.spokenAudio`, no mixing (Podcasts semantics: we pause
/// other audio, other audio pauses us). Coexists with, and never modifies,
/// `LunaReaderUI.ReaderAudioSession`: that's the LEGACY path's choke point,
/// used only by `SpeechController` (share/action extensions, and in-app until
/// Phase 3 reroutes the readers). The two never fight in practice because the
/// legacy path only activates a session when legacy playback itself starts,
/// which `AudioPlaybackCenter` supersedes in-app — see
/// `claudedocs/audio-playback-plan.md`.
public final class AudioSessionCoordinator {
    /// What the session should do in response to an interruption/route-change
    /// event — a pure decision, unit-testable independent of a real
    /// `AVAudioSession`/`NotificationCenter`. `AudioPlaybackCenter` installs
    /// `actionHandler` to translate this into its own pause()/resume().
    public enum Action: Equatable {
        case pause
        case resume
        case none
    }

    private let session = AVAudioSession.sharedInstance()
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var deactivateWorkItem: DispatchWorkItem?

    /// Grace period after a USER pause before the session actually
    /// deactivates. Now Playing info + remote command targets stay
    /// registered the entire time — that registration, not session activity,
    /// is what keeps AirPods-press-to-resume working minutes later.
    public var deactivationGrace: TimeInterval = 5

    public var actionHandler: ((Action) -> Void)?

    public init() {}

    deinit {
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        if let routeChangeObserver { NotificationCenter.default.removeObserver(routeChangeObserver) }
    }

    /// Begins observing interruptions/route changes. Idempotent. Does NOT
    /// activate the session itself — that only happens on `activate()`
    /// (i.e. when playback actually starts).
    public func start() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] notification in
            self?.handleInterruption(notification)
        }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
        ) { [weak self] notification in
            self?.handleRouteChange(notification)
        }
    }

    /// Activates `.playback`/`.spokenAudio`, no mixing options. Cancels any
    /// pending grace-period deactivation.
    public func activate() {
        deactivateWorkItem?.cancel()
        deactivateWorkItem = nil
        try? session.setCategory(.playback, mode: .spokenAudio, options: [])
        try? session.setActive(true)
    }

    /// Called on a USER pause (never on an interruption pause, which must NOT
    /// deactivate — see `handleInterruption`): after `deactivationGrace`,
    /// deactivates with `.notifyOthersOnDeactivation` so other apps' audio
    /// resumes.
    public func scheduleDeactivationAfterUserPause() {
        deactivateWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            try? self?.session.setActive(false, options: .notifyOthersOnDeactivation)
        }
        deactivateWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + deactivationGrace, execute: work)
    }

    // MARK: - Notification handling

    private func handleInterruption(_ notification: Notification) {
        guard let info = notification.userInfo,
              let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else { return }
        switch type {
        case .began:
            // Pause WITHOUT deactivating — the interruption itself already
            // took the session; deactivating on top only complicates the
            // `.ended`/`.shouldResume` bookkeeping for no benefit.
            actionHandler?(.pause)
        case .ended:
            let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            actionHandler?(options.contains(.shouldResume) ? .resume : .none)
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let info = notification.userInfo,
              let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue)
        else { return }
        // Only the device-unavailable case pauses (and keeps the session
        // active — no deactivation). Every other reason, INCLUDING
        // `.newDeviceAvailable` (e.g. AirPods connecting), is a deliberate
        // no-op: we never auto-resume just because a new route appeared.
        if reason == .oldDeviceUnavailable {
            actionHandler?(.pause)
        }
    }
}
