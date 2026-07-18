//
//  VideoCardContentViewController.swift
//  LunaDesignSystem
//
//  Time-based card content backed by AVPlayer: autoplays and loops when the
//  carousel centers it, scrubs with frame-accurate seeks, and mutes per the
//  carousel's session-wide mute state. Backed either by a local file URL or an
//  async AVPlayerItem provider (e.g. a Photos-library asset request).
//

import AVFoundation
import UIKit

public final class VideoCardContentViewController: CardContentViewController {

    /// Supplies the player item asynchronously; call the completion on any queue.
    public typealias ItemProvider = (@escaping (AVPlayerItem?) -> Void) -> Void

    private let itemProvider: ItemProvider
    private let player = AVPlayer()
    private let posterView = UIImageView()
    private var playerView: PlayerLayerView { view as! PlayerLayerView }
    private var hasAudioTrack = false
    private var wantsPlaying = false
    private var muted = true
    private var endObserver: NSObjectProtocol?
    private var readyForDisplayObservation: NSKeyValueObservation?

    public init(fileURL: URL) {
        self.itemProvider = { completion in
            completion(AVPlayerItem(url: fileURL))
        }
        super.init()
    }

    public init(itemProvider: @escaping ItemProvider) {
        self.itemProvider = itemProvider
        super.init()
    }

    deinit {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    /// Shown (aspect-fit) until the first video frame is ready.
    public func setPosterImage(_ image: UIImage?) {
        posterView.image = image
    }

    public override func loadView() {
        view = PlayerLayerView()
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        playerView.playerLayer.videoGravity = .resizeAspect
        playerView.playerLayer.player = player
        player.isMuted = true
        // Looping is handled manually on the end notification (rather than
        // AVPlayerLooper) so scrubbing and pause state stay under our control.
        player.actionAtItemEnd = .none

        posterView.contentMode = .scaleAspectFit
        posterView.frame = view.bounds
        posterView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(posterView)

        readyForDisplayObservation = playerView.playerLayer.observe(\.isReadyForDisplay) {
            [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async { self?.posterView.isHidden = true }
        }

        itemProvider { [weak self] item in
            DispatchQueue.main.async { self?.install(item) }
        }
    }

    private func install(_ item: AVPlayerItem?) {
        guard let item else { return }
        player.replaceCurrentItem(with: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            guard let self, self.wantsPlaying else { return }
            self.player.seek(to: .zero)
            self.player.play()
        }
        Task { [weak self] in
            let audioTracks = (try? await item.asset.loadTracks(withMediaType: .audio)) ?? []
            await MainActor.run {
                guard let self else { return }
                self.hasAudioTrack = !audioTracks.isEmpty
                self.audioAvailabilityChanged?()
            }
        }
        if wantsPlaying { player.play() }
    }

    // MARK: - CardContentViewController

    public override var isPlayable: Bool { true }

    public override var supportsAudio: Bool { hasAudioTrack }

    public override var isPlaying: Bool { wantsPlaying }

    public override var playbackFraction: Double {
        guard let item = player.currentItem else { return 0 }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return 0 }
        return min(max(player.currentTime().seconds / duration, 0), 1)
    }

    public override func setPlaying(_ playing: Bool) {
        wantsPlaying = playing
        if playing { player.play() } else { player.pause() }
    }

    public override func seek(toFraction fraction: Double) {
        guard let item = player.currentItem else { return }
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0 else { return }
        let clamped = min(max(fraction, 0), 1)
        let target = CMTime(seconds: clamped * duration, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    public override func setMuted(_ newMuted: Bool) {
        muted = newMuted
        player.isMuted = newMuted
    }
}

private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
