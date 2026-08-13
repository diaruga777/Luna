//
//  SetupGuideVideo.swift
//  Luna
//

import AVFoundation
import AVKit
import LunaModels
import UIKit

/// The Action Button setup guide: a muted clip that moves into Picture in
/// Picture while the user is in Settings assigning the shortcut.
@MainActor
final class SetupGuideVideo: NSObject {
    private static let resourceName = "ActionButtonGuide"

    private final class PlayerLayerView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    let playerView: UIView

    private let layerView: PlayerLayerView
    private var player: AVQueuePlayer?
    private var looper: AVPlayerLooper?
    private var pictureInPictureController: AVPictureInPictureController?
    private var possibilityObservation: NSKeyValueObservation?
    private var foregroundObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var wantsPictureInPicture = false
    private var didLoad = false
    private var didConfigureAudioSession = false

    override init() {
        layerView = PlayerLayerView()
        playerView = layerView
        super.init()
        layerView.playerLayer.videoGravity = .resizeAspectFill
        observeReturnToForeground()
    }

    deinit {
        if let foregroundObserver {
            NotificationCenter.default.removeObserver(foregroundObserver)
        }
        if let activeObserver {
            NotificationCenter.default.removeObserver(activeObserver)
        }
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

    #if DEBUG
    var pictureInPictureRequestedForTesting: Bool { wantsPictureInPicture }

    /// Exercises the lifecycle stop contract without loading a media asset or
    /// opening a PiP controller in a test process.
    func requestPictureInPictureForTesting() {
        wantsPictureInPicture = true
    }
    #endif

    private func loadIfNeeded() {
        guard !didLoad else { return }
        didLoad = true

        let base = Self.resourceName
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

    /// The guide should never resume just because its host is foregrounded
    /// again. Stop at both lifecycle boundaries: `willEnterForeground` takes
    /// PiP down immediately, while `didBecomeActive` covers a system that
    /// recreates its PiP state during activation. A new Settings tap is the
    /// only route that calls `startPictureInPicture()` and opts back in.
    private func observeReturnToForeground() {
        let center = NotificationCenter.default
        foregroundObserver = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopPictureInPicture() }
        }
        activeObserver = center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stopPictureInPicture() }
        }
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
