//
//  SetupGuideVideo.swift
//  Luna
//

import AVFoundation
import AVKit
import LunaModels
import UIKit

/// A muted setup guide that moves into Picture in Picture while the user is in
/// Safari or Settings. The clips are the former onboarding guides, now owned by
/// the left tray rather than a first-launch flow.
@MainActor
final class SetupGuideVideo: NSObject {
    enum Guide {
        case safariExtension
        case actionButton

        fileprivate var resourceName: String {
            switch self {
            case .safariExtension: return "SafariExtensionGuide"
            case .actionButton: return "ActionButtonGuide"
            }
        }
    }

    private final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    let playerView: UIView

    private let guide: Guide
    private let layerView: PlayerLayerView
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var pictureInPictureController: AVPictureInPictureController?
    private var possibilityObservation: NSKeyValueObservation?
    private var wantsPictureInPicture = false
    private var didLoad = false
    private var didConfigureAudioSession = false

    init(guide: Guide) {
        self.guide = guide
        layerView = PlayerLayerView()
        playerView = layerView
        super.init()
        layerView.playerLayer.videoGravity = .resizeAspectFill
    }

    /// Loads the clip while the tray is on screen so a later button tap can
    /// enter PiP without waiting for AVFoundation to become ready.
    func prepare() {
        loadIfNeeded()
    }

    func startPictureInPicture() {
        loadIfNeeded()
        wantsPictureInPicture = true
        configureAudioSession()
        player?.play()
        startWhenPossible()
    }

    func stopPictureInPicture() {
        wantsPictureInPicture = false
        if pictureInPictureController?.isPictureInPictureActive == true {
            pictureInPictureController?.stopPictureInPicture()
        }
        player?.pause()
    }

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true

        let base = guide.resourceName
        let surface = base + guideSuffix
        let appearance = currentAppearanceSuffix
        let candidates = [surface + appearance, surface, base + appearance, base]
        guard let url = candidates.lazy.compactMap({
            Bundle.main.url(forResource: $0, withExtension: "mp4")
        }).first else { return }

        let player = AVQueuePlayer()
        player.isMuted = true
        self.player = player
        looper = AVPlayerLooper(player: player, templateItem: AVPlayerItem(url: url))
        layerView.playerLayer.player = player

        guard AVPictureInPictureController.isPictureInPictureSupported(),
              let controller = AVPictureInPictureController(playerLayer: layerView.playerLayer)
        else { return }
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        pictureInPictureController = controller
        possibilityObservation = controller.observe(
            \.isPictureInPicturePossible, options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor in self?.startWhenPossible() }
        }
    }

    private func startWhenPossible() {
        guard wantsPictureInPicture,
              let controller = pictureInPictureController,
              controller.isPictureInPicturePossible,
              !controller.isPictureInPictureActive else { return }
        controller.startPictureInPicture()
    }

    private var guideSuffix: String {
        switch LunaApp.current {
        case .luna: return "Luna"
        case .reader: return "Reader"
        case .downloader: return "Downloader"
        case .priceTracker: return "PriceTracker"
        }
    }

    private var currentAppearanceSuffix: String {
        let style = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .traitCollection.userInterfaceStyle ?? UITraitCollection.current.userInterfaceStyle
        return style == .dark ? "Dark" : "Light"
    }

    private func configureAudioSession() {
        guard !didConfigureAudioSession else { return }
        didConfigureAudioSession = true
        DispatchQueue.global(qos: .userInitiated).async {
            try? AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }
}
