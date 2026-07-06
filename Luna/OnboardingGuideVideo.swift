//
//  OnboardingGuideVideo.swift
//  Luna
//

import AVFoundation
import AVKit
import UIKit

/// A muted, looping "how to" clip shown inline behind an onboarding step's live
/// illustration (via `OnboardingStepViewController.installBackdropView`) and mirrored
/// into Picture-in-Picture right before the step sends the user out of Luna (into
/// Safari or Settings) to make the actual change being demonstrated — so the guide
/// keeps floating over whatever app they land in.
///
/// The bundled clip (`Luna/Resources/<resourceName>.mp4`) is only a handful of
/// seconds; `AVPlayerLooper` repeats it without building a long composition up
/// front, so the next onboarding screen can appear immediately and PiP has a
/// moving player item as soon as the user leaves Luna.
final class OnboardingGuideVideo: NSObject {

    /// Hosts the `AVPlayerLayer`. A plain `UIView` subclass so it composes with
    /// `installBackdropView`'s Auto Layout pinning like any other view.
    private final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    /// Install this behind the hosting step's animation via
    /// `OnboardingStepViewController.installBackdropView(_:)`.
    let playerView: UIView

    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var pipController: AVPictureInPictureController?

    /// - Parameter resourceName: bundled mp4 base name (without extension), expected
    ///   under `Luna/Resources/`. Silently does nothing if the resource is missing —
    ///   playback/PiP calls just become no-ops.
    init(resourceName: String) {
        let layerView = PlayerLayerView()
        playerView = layerView
        super.init()

        layerView.translatesAutoresizingMaskIntoConstraints = false
        layerView.playerLayer.player = player
        layerView.playerLayer.videoGravity = .resizeAspectFill
        player.isMuted = true
        player.actionAtItemEnd = .none

        if AVPictureInPictureController.isPictureInPictureSupported() {
            let pip = AVPictureInPictureController(playerLayer: layerView.playerLayer)
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
            pipController = pip
        }

        if let url = Bundle.main.url(forResource: resourceName, withExtension: "mp4") {
            let item = AVPlayerItem(url: url)
            looper = AVPlayerLooper(player: player, templateItem: item)
        }
    }

    /// Starts (or resumes) inline playback. Call once the hosting step is on screen.
    func play() {
        configureAudioSession()
        player.play()
    }

    /// Programmatic PiP start — call right before sending the user out of the app
    /// (opening Safari or Settings) so the guide clip keeps playing over whatever
    /// they navigate to next. A no-op wherever PiP isn't available (e.g. some
    /// Simulator runtimes) — never crashes or blocks the caller.
    func startPictureInPicture() {
        guard let pipController, pipController.isPictureInPicturePossible,
              !pipController.isPictureInPictureActive
        else { return }
        configureAudioSession()
        player.play()
        pipController.startPictureInPicture()
    }

    /// Stops PiP — call when the step returns to the foreground, or when the step
    /// is left (advancing to the next step / finishing onboarding).
    func stopPictureInPicture() {
        guard let pipController, pipController.isPictureInPictureActive else { return }
        pipController.stopPictureInPicture()
    }

    private func configureAudioSession() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
    }

}
