import UIKit
import AVKit
import LunaVaultSync

/// A native player with client-only watch history and a lightweight Up Next card.
@MainActor
public final class VaultVideoPlayerViewController: UIViewController {
    public typealias SourceProvider = @Sendable (String) async throws -> VaultMediaSource
    private let history: VaultVideoHistory
    private let sourceProvider: SourceProvider
    private let siblingsProvider: @Sendable () async throws -> [String]
    private let controller = AVPlayerViewController()
    private let player = AVPlayer()
    private var source: VaultMediaSource
    private var loader: VaultVideoResourceLoader?
    private var thumbnailLoader: VaultVideoResourceLoader?
    private var generator: AVAssetImageGenerator?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var backgroundObserver: NSObjectProtocol?
    private var task: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var siblings: [String] = []
    private var nextPath: String?
    private var restored = false
    private var finished = false
    private var lastSave: Double = -1
    private var nextButton = UIButton(type: .system)
    private let replayButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private let optionsButton = UIButton(type: .system)
    private let errorLabel = UILabel()
    private var thumbnail: UIImage?

    public init(source: VaultMediaSource, history: VaultVideoHistory,
                sourceProvider: @escaping SourceProvider,
                siblingsProvider: @escaping @Sendable () async throws -> [String]) {
        self.source = source; self.history = history
        self.sourceProvider = sourceProvider; self.siblingsProvider = siblingsProvider
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }
    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        addChild(controller); controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view); controller.didMove(toParent: self)
        controller.player = player
        // The stream uses an app-authenticated byte source, so it cannot be
        // handed directly to a remote AirPlay receiver.
        player.allowsExternalPlayback = false
        controller.allowsPictureInPicturePlayback = false
        controller.speeds = AVPlaybackSpeed.systemDefaultSpeeds
        let restart = UIAction(title: "Play from Start", image: UIImage(systemName: "arrow.counterclockwise")) { [weak self] _ in
            self?.restart()
        }
        let back = UIAction(title: "Back 15 Seconds", image: UIImage(systemName: "gobackward.15")) { [weak self] _ in self?.skip(-15) }
        let forward = UIAction(title: "Forward 15 Seconds", image: UIImage(systemName: "goforward.15")) { [weak self] _ in self?.skip(15) }
        optionsButton.menu = UIMenu(children: [restart, back, forward])
        optionsButton.showsMenuAsPrimaryAction = true
        configureOverlay()
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        rateObservation = player.observe(\.rate) { [weak self] _, _ in
            Task { @MainActor in self?.save(); self?.updateOverlay() }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, note.object as? AVPlayerItem === self.player.currentItem else { return }
                self.finished = true; self.save(); self.updateOverlay()
            }
        }
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.save(); self?.player.pause() }
        }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch { NSLog("Vault video audio session: %@", error.localizedDescription) }
        load(source)
        task = Task { [weak self, siblingsProvider] in
            let siblings = (try? await siblingsProvider()) ?? []
            guard let self, !Task.isCancelled else { return }
            self.siblings = siblings; findNext()
        }
    }

    private func configureOverlay() {
        guard let overlay = controller.contentOverlayView else { return }
        closeButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        closeButton.tintColor = .white
        closeButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 28), forImageIn: .normal)
        closeButton.accessibilityLabel = "Close Video"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        replayButton.setTitle("Play Again", for: .normal)
        replayButton.addAction(UIAction { [weak self] _ in self?.restart() }, for: .touchUpInside)
        nextButton.accessibilityIdentifier = "vault.video.nextEpisode"
        nextButton.addAction(UIAction { [weak self] _ in self?.playNext() }, for: .touchUpInside)
        errorLabel.textColor = .white; errorLabel.numberOfLines = 0; errorLabel.textAlignment = .center
        optionsButton.setImage(UIImage(systemName: "ellipsis.circle.fill"), for: .normal)
        optionsButton.tintColor = .white
        optionsButton.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 28), forImageIn: .normal)
        optionsButton.accessibilityLabel = "Video Options"
        for control in [closeButton, optionsButton, replayButton, nextButton, errorLabel] {
            control.translatesAutoresizingMaskIntoConstraints = false; overlay.addSubview(control)
        }
        nextButton.backgroundColor = UIColor.black.withAlphaComponent(0.82)
        nextButton.layer.cornerRadius = 14; nextButton.clipsToBounds = true
        NSLayoutConstraint.activate([
            closeButton.leadingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            closeButton.topAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.topAnchor, constant: 12),
            closeButton.widthAnchor.constraint(equalToConstant: 44), closeButton.heightAnchor.constraint(equalToConstant: 44),
            optionsButton.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            optionsButton.topAnchor.constraint(equalTo: closeButton.topAnchor),
            optionsButton.widthAnchor.constraint(equalToConstant: 44), optionsButton.heightAnchor.constraint(equalToConstant: 44),
            nextButton.trailingAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            nextButton.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -100),
            nextButton.widthAnchor.constraint(equalToConstant: 190), nextButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 122),
            replayButton.centerXAnchor.constraint(equalTo: overlay.centerXAnchor), replayButton.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            errorLabel.centerXAnchor.constraint(equalTo: overlay.centerXAnchor), errorLabel.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            errorLabel.widthAnchor.constraint(lessThanOrEqualTo: overlay.widthAnchor, multiplier: 0.8)
        ])
    }
    private func load(_ newSource: VaultMediaSource) {
        player.allowsExternalPlayback = newSource.localURL != nil
        source = newSource; restored = false; finished = false; lastSave = -1
        errorLabel.text = nil; thumbnail = nil
        thumbnailTask?.cancel(); generator?.cancelAllCGImageGeneration(); thumbnailLoader?.cancel()
        thumbnailTask = nil; generator = nil; thumbnailLoader = nil
        statusObservation = nil; loader?.cancel(); loader = nil
        let item: AVPlayerItem
        if let url = source.localURL { item = AVPlayerItem(url: url) }
        else {
            let loader = VaultVideoResourceLoader(source: source); self.loader = loader
            item = AVPlayerItem(asset: loader.asset)
        }
        item.preferredForwardBufferDuration = 15
        player.replaceCurrentItem(with: item)
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.player.currentItem === item else { return }
                if item.status == .readyToPlay, !self.restored {
                    let saved = (try? self.history.progress(for: self.source.identity))?.resumeSeconds ?? 0
                    let duration = item.duration.seconds
                    let seconds = duration.isFinite && saved < duration ? saved : 0
                    await self.player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    guard self.player.currentItem === item, !Task.isCancelled else { return }
                    self.restored = true
                    self.player.play()
                } else if item.status == .failed {
                    self.errorLabel.text = "Couldn’t play this video.\nCheck your Mac connection and try opening it again.\nThis video may use an unsupported format."
                    self.updateOverlay()
                }
            }
        }
        findNext(); updateOverlay()
    }
    private func findNext() {
        nextPath = VaultVideoEpisodes.next(after: source.name, siblings: siblings)
        updateOverlay()
    }
    private func tick() {
        let seconds = player.currentTime().seconds
        if abs(seconds - lastSave) >= 5 { save() }
        updateOverlay()
    }
    private func save() {
        guard restored, let item = player.currentItem, item.status == .readyToPlay else { return }
        let seconds = player.currentTime().seconds, duration = item.duration.seconds
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return }
        do {
            try history.save(VaultVideoProgress(seconds: seconds, duration: duration, completed: finished), for: source.identity)
            lastSave = seconds
        } catch { NSLog("Vault video history could not be saved: %@", error.localizedDescription) }
    }
    private func updateOverlay() {
        let seconds = player.currentTime().seconds, duration = player.currentItem?.duration.seconds ?? .nan
        let visible = nextPath != nil && VaultVideoEpisodes.showsNext(seconds: seconds, duration: duration, paused: player.rate == 0)
        nextButton.isHidden = !visible
        replayButton.isHidden = !finished
        if visible, let nextPath {
            var config = UIButton.Configuration.plain()
            config.baseForegroundColor = .white
            config.title = "Up Next"
            config.subtitle = (nextPath as NSString).lastPathComponent
            config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming; out.font = UIFont.preferredFont(forTextStyle: .headline); return out
            }
            config.subtitleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
                var out = incoming; out.font = UIFont.preferredFont(forTextStyle: .caption1); return out
            }
            config.subtitleLineBreakMode = .byTruncatingMiddle
            config.image = thumbnail ?? UIImage(systemName: "play.rectangle.fill")
            config.imagePlacement = .top; config.imagePadding = 6
            config.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10)
            nextButton.configuration = config
            nextButton.accessibilityLabel = "Play next episode, \((nextPath as NSString).lastPathComponent)"
            if thumbnailTask == nil { loadThumbnail(nextPath) }
        }
    }
    private func loadThumbnail(_ path: String) {
        thumbnailTask = Task { [weak self, sourceProvider] in
            do {
                let source = try await sourceProvider(path)
                try Task.checkCancellation()
                guard let self else { return }
                let asset: AVAsset
                if let url = source.localURL { asset = AVURLAsset(url: url) }
                else {
                    let loader = VaultVideoResourceLoader(source: source); thumbnailLoader = loader; asset = loader.asset
                }
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 320, height: 120)
                self.generator = generator
                let ownedLoader = thumbnailLoader
                defer {
                    ownedLoader?.cancel()
                    if self.generator === generator { self.generator = nil; thumbnailLoader = nil }
                }
                let result = try await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600))
                try Task.checkCancellation()
                guard nextPath == path else { return }
                thumbnail = UIImage(cgImage: result.image, scale: 2, orientation: .up); updateOverlay()
            } catch { /* A missing thumbnail must never interrupt playback. */ }
        }
    }
    private func playNext() {
        guard let path = nextPath else { return }
        save(); player.pause(); nextButton.isEnabled = false
        task?.cancel()
        task = Task { [weak self, sourceProvider] in
            do {
                let next = try await sourceProvider(path)
                try Task.checkCancellation()
                self?.load(next)
            } catch {
                guard let self, !Task.isCancelled else { return }
                let alert = UIAlertController(title: "Couldn’t Open Episode", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default)); present(alert, animated: true)
            }
            self?.nextButton.isEnabled = true
        }
    }
    private func restart() {
        finished = false
        player.seek(to: .zero) { [weak self] _ in Task { @MainActor in self?.save(); self?.player.play() } }
    }
    private func skip(_ seconds: Double) {
        guard let duration = player.currentItem?.duration.seconds, duration.isFinite else { return }
        finished = false
        player.seek(to: CMTime(seconds: max(0, min(duration, player.currentTime().seconds + seconds)), preferredTimescale: 600))
    }
    public override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        save(); player.pause()
    }
    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { shutdown() }
    }
    private func shutdown() {
        task?.cancel(); thumbnailTask?.cancel(); generator?.cancelAllCGImageGeneration()
        thumbnailLoader?.cancel(); loader?.cancel(); player.replaceCurrentItem(with: nil)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    deinit {
        task?.cancel(); thumbnailTask?.cancel()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let backgroundObserver { NotificationCenter.default.removeObserver(backgroundObserver) }
    }
}
