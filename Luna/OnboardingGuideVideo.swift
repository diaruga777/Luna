//
//  OnboardingGuideVideo.swift
//  Luna
//

import AVFoundation
import AVKit
import LunaSocialUI
import UIKit

/// A muted, looping "how to" clip kept playing (covered) behind an onboarding
/// step's live illustration (via `OnboardingStepViewController.installBackdropView`)
/// and mirrored into Picture-in-Picture right before the step sends the user out of
/// Luna (into Safari or Settings) to make the actual change being demonstrated — so
/// the guide keeps floating over whatever app they land in.
///
/// `init` is deliberately trivial: the step factories construct one of these at
/// step-creation time — i.e. inside the previous step's button handler — and the
/// AVFoundation/AVKit stack (player item, looper, `AVPictureInPictureController`)
/// is expensive enough to visibly stall that push transition. All of it is built
/// lazily in `play()`, which runs from the step's `viewDidAppear` instead.
final class OnboardingGuideVideo: NSObject {

    /// The two visual loops that need to survive an out-of-app onboarding hop.
    /// Each is generated once per Luna app icon by the Debug-simulator build
    /// phase, keeping PiP visually consistent with the live UIKit illustration.
    enum Guide {
        case safariExtension
        case actionButton

        fileprivate var baseResourceName: String {
            switch self {
            case .safariExtension: return "SafariExtensionGuide"
            case .actionButton: return "ActionButtonGuide"
            }
        }
    }

    /// Hosts the `AVPlayerLayer`. A plain `UIView` subclass so it composes with
    /// `installBackdropView`'s Auto Layout pinning like any other view.
    private final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    /// Install this behind the hosting step's animation via
    /// `OnboardingStepViewController.installBackdropView(_:)`.
    let playerView: UIView

    private let surfaceResourceName: String
    private let fallbackResourceNames: [String]
    private let layerView: PlayerLayerView
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var pipController: AVPictureInPictureController?
    private var didLoad = false

    /// Resolves a surface-specific bundled MP4 (without extension) from
    /// `Luna/Resources/`. The unsuffixed, legacy Reader clip remains a fallback so
    /// PiP is still available if a developer cannot record fresh clips locally.
    init(guide: Guide) {
        let baseName = guide.baseResourceName
        let surfaceName = baseName + Self.currentGuideSuffix
        self.surfaceResourceName = surfaceName
        self.fallbackResourceNames = [surfaceName, baseName]
        layerView = PlayerLayerView()
        playerView = layerView
        super.init()
        layerView.translatesAutoresizingMaskIntoConstraints = false
        layerView.playerLayer.videoGravity = .resizeAspectFill
    }

    /// Builds the player + looper + PiP controller on first use. Main thread only.
    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true
        let candidates = [surfaceResourceName + Self.currentAppearanceSuffix] + fallbackResourceNames
        guard let url = candidates.lazy.compactMap({
            Bundle.main.url(forResource: $0, withExtension: "mp4")
        }).first
        else { return }

        let player = AVQueuePlayer()
        player.isMuted = true
        self.player = player
        // NOTE: leave `actionAtItemEnd` alone — AVPlayerLooper requires the default
        // (`.advance`); overriding it to `.none` freezes playback at the first loop's end.
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        layerView.playerLayer.player = player

        if AVPictureInPictureController.isPictureInPictureSupported() {
            let pip = AVPictureInPictureController(playerLayer: layerView.playerLayer)
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
            pipController = pip
        }
    }

    /// Starts (or resumes) playback. Call once the hosting step is on screen
    /// (`viewDidAppear`) — the first call also builds the whole AV stack.
    func play() {
        loadIfNeeded()
        configureAudioSession()
        player?.play()
    }

    /// Programmatic PiP start — call right before sending the user out of the app
    /// (opening Safari or Settings) so the guide clip keeps playing over whatever
    /// they navigate to next. A no-op wherever PiP isn't available (e.g. some
    /// Simulator runtimes) — never crashes or blocks the caller.
    func startPictureInPicture() {
        loadIfNeeded()
        guard let pipController, pipController.isPictureInPicturePossible,
              !pipController.isPictureInPictureActive
        else { return }
        configureAudioSession()
        player?.play()
        pipController.startPictureInPicture()
    }

    /// Stops PiP — call when the step returns to the foreground, or when the step
    /// is left (advancing to the next step / finishing onboarding).
    func stopPictureInPicture() {
        guard let pipController, pipController.isPictureInPictureActive else { return }
        pipController.stopPictureInPicture()
    }

    private var didConfigureAudioSession = false

    private static var currentGuideSuffix: String {
        OnboardingAnimationView.AppIcon.currentBundle.guideVideoSuffix
    }

    /// Resolve appearance when the AV stack is first loaded, not when the step is
    /// constructed. A user can change system appearance while onboarding is alive;
    /// the clip entering PiP must match the interface at playback start.
    private static var currentAppearanceSuffix: String {
        let style = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .traitCollection.userInterfaceStyle ?? UITraitCollection.current.userInterfaceStyle
        return style == .dark ? "Dark" : "Light"
    }

    private func configureAudioSession() {
        // `.playback` (+ background-mode `audio` from Luna.xcconfig) is what keeps
        // the clip running once the app is backgrounded into PiP. `setActive` can
        // block for a noticeable beat, so it runs off the main thread —
        // AVAudioSession is thread-safe, and playback doesn't depend on it having
        // finished (only backgrounded PiP does, well after the hop completes).
        guard !didConfigureAudioSession else { return }
        didConfigureAudioSession = true
        DispatchQueue.global(qos: .userInitiated).async {
            try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

}
