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
/// seconds; loading builds an `AVMutableComposition` that repeats it enough times to
/// clear five minutes, so a user who dawdles before returning still has the loop
/// running (repetition at load time, rather than shipping a multi-minute asset).
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

    private let player = AVPlayer()
    private var pipController: AVPictureInPictureController?

    /// How long the looped composition should run in total — long enough that a
    /// slow user still has it playing by the time they act on it.
    private static let minimumDuration = CMTime(seconds: 5 * 60, preferredTimescale: 600)

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

        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "mp4") else { return }
        Task { [player] in
            await Self.loadLoopingItem(from: url, into: player)
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

    /// Builds a looping composition from `url` (repeating its single track until the
    /// total exceeds `minimumDuration`) and swaps it into `player`.
    private static func loadLoopingItem(from url: URL, into player: AVPlayer) async {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0,
              let assetTrack = try? await asset.loadTracks(withMediaType: .video).first
        else { return }

        let composition = AVMutableComposition()
        guard let compositionTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return }

        let range = CMTimeRange(start: .zero, duration: duration)
        var inserted = CMTime.zero
        while inserted < minimumDuration {
            try? compositionTrack.insertTimeRange(range, of: assetTrack, at: inserted)
            inserted = inserted + duration
        }

        let item = AVPlayerItem(asset: composition)
        await MainActor.run {
            player.replaceCurrentItem(with: item)
            player.play()
        }
    }
}
