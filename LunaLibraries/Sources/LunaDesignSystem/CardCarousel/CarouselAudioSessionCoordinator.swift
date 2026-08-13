//
//  CarouselAudioSessionCoordinator.swift
//  LunaDesignSystem
//
//  The carousel's mute state, its shared-AVAudioSession category switching, and
//  the hardware-volume observation that unmutes on a physical volume press.
//  Sound is off by default; muted playback keeps the session ambient so it
//  never silences other apps' audio, while unmuted playback claims the
//  session so it's audible even with the silent switch on. The carousel
//  itself still owns applying the resulting mute state to its mounted slots —
//  The delegate is how it hears about a change, whether from its own
//  mute button or from this object's own auto-unmute.
//

import AVFoundation
import Foundation

/// The carousel, which re-applies a changed mute state to its mounted slots.
protocol CarouselAudioSessionCoordinatorDelegate: AnyObject {
    func carouselAudioSessionDidChangeMuteState(_ coordinator: CarouselAudioSessionCoordinator)
}

final class CarouselAudioSessionCoordinator {

    /// Whether the coordinator drives the shared AVAudioSession (ambient while
    /// muted, playback while unmuted). Hosts with their own audio coordination
    /// can turn this off.
    var managesAudioSession = true

    private(set) var isMuted = true
    private var volumeObservation: NSKeyValueObservation?

    /// Told after `isMuted` changes, so the carousel can re-apply mute state to
    /// its mounted slots.
    weak var delegate: CarouselAudioSessionCoordinatorDelegate?

    func setMuted(_ muted: Bool) {
        isMuted = muted
        delegate?.carouselAudioSessionDidChangeMuteState(self)
        updateAudioSession()
    }

    func startVolumeObservation() {
        updateAudioSession()
        volumeObservation = AVAudioSession.sharedInstance().observe(
            \.outputVolume, options: [.old, .new]
        ) { [weak self] _, change in
            guard let old = change.oldValue, let new = change.newValue, old != new
            else { return }
            DispatchQueue.main.async {
                guard let self, self.isMuted else { return }
                self.setMuted(false)
            }
        }
    }

    func stopVolumeObservation() {
        volumeObservation?.invalidate()
        volumeObservation = nil
    }

    private func updateAudioSession() {
        guard managesAudioSession else { return }
        let session = AVAudioSession.sharedInstance()
        // Muted autoplay must not silence other apps' audio; unmuted playback
        // should be audible even with the silent switch on.
        if isMuted {
            try? session.setCategory(.ambient, options: [.mixWithOthers])
        } else {
            try? session.setCategory(.playback)
        }
        try? session.setActive(true)
    }
}
