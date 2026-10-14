import UIKit
import Combine
import AVKit
import MediaPlayer
import LunaPodcastCore
import LunaMusicCore

extension MusicScreenViewController {
    func presentPodcastPlayer(queue: Bool = false) {
        view.endEditing(true)
        let controller = UINavigationController(rootViewController: PodcastPlayerViewController(showQueue: queue))
        controller.modalPresentationStyle = .fullScreen
        present(controller, animated: true)
    }
}

/// Only the upper stage changes when opening the queue. Seeking, transport,
/// volume and output controls keep their positions throughout the transition.
@MainActor final class PodcastPlayerViewController: UIViewController, UIGestureRecognizerDelegate {
    private let player: PodcastPlaybackController
    private let library: PodcastLibraryController
    private let backdrop = UIImageView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let shade = CAGradientLayer()
    private let stage = UIView()
    private let grabber = UIView()
    private let close = UIButton(type: .custom)
    private let artwork = UIImageView()
    private let names = UIView()
    private let titleLabel = PodcastPlayerTitleView()
    private let dateLabel = UILabel(), showLabel = UILabel(), elapsed = UILabel(), remaining = UILabel()
    private let more = UIButton(type: .system)
    private let slider = UISlider()
    private let transport = UIView()
    private let volume = MPVolumeView()
    private let volumeLow = UIImageView(image: UIImage(systemName: "speaker.fill"))
    private let volumeHigh = UIImageView(image: UIImage(systemName: "speaker.wave.3.fill"))
    private let options = UIStackView()
    private let route = AVRoutePickerView()
    private var play: UIButton!, speed: UIButton!, sleep: UIButton!, back: UIButton!, forward: UIButton!, queueButton: UIButton!
    private var queueSwitch: MediaPlayerQueueSwitch!
    private lazy var queue = PodcastQueueViewController(library: library)
    private let queueMask = CAGradientLayer()
    private var subscriptions = Set<AnyCancellable>()
    private var artworkID: URL?
    private var artworkTask: Task<Void, Never>?
    private(set) var showsQueue: Bool
    private var queueProgress: CGFloat
    private var panStart: CGFloat = 0
    private var animator: UIViewPropertyAnimator?
    private lazy var queuePan = UIPanGestureRecognizer(target: self, action: #selector(panQueue(_:)))

    init(showQueue: Bool, player: PodcastPlaybackController = .shared, library: PodcastLibraryController = .shared) {
        self.player = player; self.library = library
        showsQueue = showQueue; queueProgress = showQueue ? 1 : 0
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(white: 0.16, alpha: 1)
        view.tintColor = .white
        backdrop.contentMode = .scaleAspectFill; backdrop.clipsToBounds = true; backdrop.alpha = 0.5
        shade.colors = [UIColor.black.withAlphaComponent(0.1).cgColor, UIColor.black.withAlphaComponent(0.55).cgColor]
        [backdrop, blur].forEach(view.addSubview)
        view.layer.addSublayer(shade)
        [stage, grabber, close, slider, elapsed, remaining, transport, volume, volumeLow, volumeHigh, options].forEach(view.addSubview)
        stage.clipsToBounds = true
        [artwork, names, more].forEach(stage.addSubview)
        artwork.layer.cornerRadius = 10; artwork.clipsToBounds = true; artwork.backgroundColor = .secondarySystemBackground
        artwork.isUserInteractionEnabled = true
        artwork.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openVideo)))
        grabber.backgroundColor = UIColor.white.withAlphaComponent(0.5); grabber.layer.cornerRadius = 2
        close.accessibilityLabel = "Close Now Playing"
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        close.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(panDismiss(_:))))
        titleLabel.font = MusicStyle.font(24, weight: .semibold)
        showLabel.font = MusicStyle.font(24); dateLabel.font = MusicStyle.font(18)
        for label in [showLabel, dateLabel, elapsed, remaining] {
            label.adjustsFontForContentSizeCategory = true
            label.textColor = UIColor.white.withAlphaComponent(0.5)
        }
        showLabel.lineBreakMode = .byTruncatingTail
        [dateLabel, titleLabel, showLabel].forEach(names.addSubview)
        more.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .semibold)), for: .normal)
        more.accessibilityLabel = "Episode Actions"; more.showsMenuAsPrimaryAction = true

        elapsed.accessibilityIdentifier = "podcasts.playback.elapsed"
        remaining.accessibilityIdentifier = "podcasts.playback.remaining"
        slider.accessibilityLabel = "Episode Position"
        slider.minimumTrackTintColor = UIColor.white.withAlphaComponent(0.65)
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 3, height: 3)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
        }
        slider.setThumbImage(thumb, for: .normal)
        slider.addAction(UIAction { [weak self] _ in guard let self else { return }; self.updateScrubbingTime(); if !self.slider.isTracking { self.player.seek(to: Double(self.slider.value)) } }, for: .valueChanged)
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.player.seek(to: Double(self.slider.value))
        }, for: [.touchUpInside, .touchUpOutside])
        slider.addAction(UIAction { [weak self] _ in self?.refresh() }, for: .touchCancel)
        elapsed.font = MusicStyle.font(17, weight: .medium); remaining.font = elapsed.font; remaining.textAlignment = .right
        back = MusicStyle.plainButton("gobackward.15", label: "Skip Back", size: 32) { MediaPlaybackCoordinator.shared.skip(.backward) }
        play = MusicStyle.plainButton("play.fill", label: "Play", size: 48) { [weak self] in self?.player.toggle() }
        forward = MusicStyle.plainButton("goforward.30", label: "Skip Forward", size: 32) { MediaPlaybackCoordinator.shared.skip(.forward) }
        speed = UIButton(configuration: .plain()); speed.showsMenuAsPrimaryAction = true; speed.accessibilityLabel = "Playback Speed"
        speed.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = MusicStyle.font(16, weight: .semibold); return attributes
        }
        speed.menu = UIMenu(title: "Playback Speed", children: [Float(0.5), 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3].map { value in
            UIAction(title: "\(value.formatted())×") { [weak self] _ in self?.player.setRate(value) }
        })
        sleep = MusicStyle.plainButton("moon.zzz.fill", label: "Sleep Timer", size: 12) {}; sleep.showsMenuAsPrimaryAction = true
        sleep.menu = UIMenu(title: "Sleep Timer", children: [UIAction(title: "Off") { [weak self] _ in self?.player.setSleepTimer(minutes: nil) }] + [5, 10, 15, 30, 45, 60].map { minutes in
            UIAction(title: "\(minutes) minutes") { [weak self] _ in self?.player.setSleepTimer(minutes: minutes) }
        } + [UIAction(title: "When Current Episode Ends") { [weak self] _ in self?.player.setSleepTimer(minutes: nil, endOfEpisode: true) }])
        [speed!, back!, play!, forward!, sleep!].forEach { button in
            button.configuration?.baseForegroundColor = .white
            button.configuration?.contentInsets = .zero
            transport.addSubview(button)
        }
        speed.configuration?.baseForegroundColor = UIColor.white.withAlphaComponent(0.5)
        sleep.configuration?.baseForegroundColor = UIColor.white.withAlphaComponent(0.5)
        volume.showsRouteButton = false; volume.tintColor = UIColor.white.withAlphaComponent(0.5)
        volume.setVolumeThumbImage(UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }, for: .normal)
        volume.accessibilityIdentifier = "podcasts.playback.volume"; volume.accessibilityLabel = "Volume"
        for image in [volumeLow, volumeHigh] { image.tintColor = UIColor.white.withAlphaComponent(0.5); image.contentMode = .scaleAspectFit }
        route.tintColor = UIColor.white.withAlphaComponent(0.5); route.activeTintColor = .white; route.accessibilityLabel = "AirPlay and Audio Output"
        let transcript = MusicStyle.plainButton("quote.bubble", label: "Transcript", size: 17) { [weak self] in self?.open(PodcastTranscriptViewController()) }
        transcript.configuration?.baseForegroundColor = UIColor.white.withAlphaComponent(0.5)
        queueButton = MusicStyle.plainButton("list.bullet", label: "Playing Next", size: 18) { [weak self] in
            guard let self else { return }; self.setQueue(!self.showsQueue)
        }
        queueButton.accessibilityIdentifier = "podcasts.playback.queueButton"
        [transcript, route, queueButton!].forEach(options.addArrangedSubview)
        options.distribution = .fillEqually
        queueSwitch = MediaPlayerQueueSwitch(owner: self, surface: .podcasts, showsQueue: { [weak self] in self?.showsQueue ?? false })
        // Keep Luna's extra actions in the episode menu, leaving Apple's three
        // bottom controls and five transport controls in their reference positions.
        addChild(queue); stage.addSubview(queue.view); queue.didMove(toParent: self)
        queue.view.layer.mask = queueMask
        queueMask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        queueMask.locations = [0, 0.9, 1]
        queuePan.delegate = self; stage.addGestureRecognizer(queuePan)
        stage.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Show Queue", actionHandler: { [weak self] _ in self?.setQueue(true); return true }), UIAccessibilityCustomAction(name: "Show Artwork", actionHandler: { [weak self] _ in self?.setQueue(false); return true })]
        player.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &subscriptions)
        library.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIAccessibility.reduceMotionStatusDidChangeNotification).sink { [weak self] _ in self?.titleLabel.setNeedsLayout() }.store(in: &subscriptions)
        refresh(); updateQueueAccessibility()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
    }
    private func open(_ controller: UIViewController) { navigationController?.pushViewController(controller, animated: true) }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backdrop.frame = view.bounds.insetBy(dx: -60, dy: -60); blur.frame = view.bounds
        CATransaction.begin(); CATransaction.setDisableActions(true); shade.frame = view.bounds; CATransaction.commit()
        let safe = view.safeAreaInsets
        let landscape = view.bounds.width > view.bounds.height
        let width = min(560, landscape ? view.bounds.width * 0.46 : view.bounds.width - 64)
        let left = landscape ? view.bounds.width - width - max(24, safe.right) : (view.bounds.width - width) / 2
        let top = max(safe.top + 32, 80)
        let bottom = view.bounds.height - max(safe.bottom, 12) - 12
        let height = bottom - top
        let controlsHeight = landscape ? height : min(270, height * 0.42)
        let timelineY = landscape ? top : bottom - controlsHeight
        stage.frame = landscape
            ? CGRect(x: max(24, safe.left), y: top, width: max(0, view.bounds.width * 0.44 - max(24, safe.left)), height: max(0, height))
            : CGRect(x: left, y: top, width: width, height: max(0, timelineY - top - 12))
        grabber.frame = CGRect(x: view.bounds.midX - 29, y: max(12, safe.top + 8), width: 58, height: 4)
        close.frame = CGRect(x: view.bounds.midX - 60, y: max(0, safe.top - 12), width: 120, height: 44)
        slider.frame = CGRect(x: left, y: timelineY - 10, width: width, height: 44)
        elapsed.frame = CGRect(x: left, y: timelineY + 25, width: width / 2, height: max(22, elapsed.font.lineHeight))
        remaining.frame = CGRect(x: left + width / 2, y: elapsed.frame.minY, width: width / 2, height: elapsed.bounds.height)
        transport.frame = CGRect(x: left, y: timelineY + controlsHeight * 0.25, width: width, height: controlsHeight * 0.36)
        for (button, position) in zip([speed!, back!, play!, forward!, sleep!], [CGFloat(0.055), 0.24, 0.5, 0.76, 0.98]) {
            let buttonWidth = max(44, width * (button === play ? 0.22 : 0.17))
            button.frame = CGRect(x: width * position - buttonWidth / 2, y: 0, width: buttonWidth, height: transport.bounds.height)
        }
        volume.frame = CGRect(x: left + 24, y: bottom - 78, width: width - 56, height: 32)
        volumeLow.frame = CGRect(x: left, y: bottom - 72, width: 12, height: 18)
        volumeHigh.frame = CGRect(x: left + width - 22, y: bottom - 72, width: 22, height: 18)
        options.frame = CGRect(x: left, y: bottom - 48, width: width, height: 44)
        updateQueueAccessibility()
        layoutStage()
    }

    private func layoutStage() {
        let width = stage.bounds.width, height = stage.bounds.height
        let titleHeight = ceil(titleLabel.font.lineHeight), showHeight = ceil(showLabel.font.lineHeight), dateHeight = ceil(dateLabel.font.lineHeight)
        let expandedNamesHeight = titleHeight + showHeight + dateHeight + 6
        let compactNamesHeight = titleHeight + showHeight + 2
        let compactSide = max(70, compactNamesHeight)
        let side = max(0, min(width, height - expandedNamesHeight - 42))
        let expandedArt = CGRect(x: (width - side) / 2, y: 0, width: side, height: side)
        let compactArt = CGRect(x: 0, y: 0, width: compactSide, height: compactSide)
        let expandedNames = CGRect(x: 0, y: max(0, height - expandedNamesHeight - 8), width: max(0, width - 44), height: expandedNamesHeight)
        let compactNames = CGRect(x: compactSide + 12, y: (compactSide - compactNamesHeight) / 2, width: max(0, width - compactSide - 56), height: compactNamesHeight)
        func mix(_ start: CGRect, _ end: CGRect) -> CGRect {
            CGRect(x: start.minX + (end.minX - start.minX) * queueProgress, y: start.minY + (end.minY - start.minY) * queueProgress,
                   width: start.width + (end.width - start.width) * queueProgress, height: start.height + (end.height - start.height) * queueProgress)
        }
        artwork.frame = mix(expandedArt, compactArt); names.frame = mix(expandedNames, compactNames)
        dateLabel.frame = CGRect(x: 0, y: 0, width: names.bounds.width, height: dateHeight)
        dateLabel.alpha = 1 - queueProgress; dateLabel.accessibilityElementsHidden = showsQueue
        let titleY = (dateHeight + 4) * (1 - queueProgress)
        titleLabel.frame = CGRect(x: 0, y: titleY, width: names.bounds.width, height: titleHeight)
        showLabel.frame = CGRect(x: 0, y: titleY + titleHeight + 2, width: names.bounds.width, height: showHeight)
        more.frame = CGRect(x: width - 36, y: names.frame.minY + titleY + titleHeight / 2 - 22, width: 44, height: 44)
        let queueY = compactSide + 20 + (1 - queueProgress) * 160
        queue.view.frame = CGRect(x: 0, y: queueY, width: width, height: max(0, height - queueY))
        queue.view.alpha = queueProgress; queue.view.isUserInteractionEnabled = showsQueue; queue.view.accessibilityElementsHidden = !showsQueue
        CATransaction.begin(); CATransaction.setDisableActions(true); queueMask.frame = queue.view.bounds; CATransaction.commit()
    }

    func setQueue(_ show: Bool, animated: Bool = true) {
        stopTransition(); showsQueue = show; updateQueueAccessibility(); panStart = queueProgress
        let changes = { self.queueProgress = show ? 1 : 0; self.layoutStage() }
        guard animated, !UIAccessibility.isReduceMotionEnabled else { changes(); return }
        let animation = UIViewPropertyAnimator(duration: 0.42, dampingRatio: 0.88, animations: changes)
        animator = animation; animation.startAnimation()
    }
    private func updateQueueAccessibility() {
        view.accessibilityIdentifier = showsQueue ? "podcasts.playback.queue" : "podcasts.playback.nowPlaying"
        queueButton.isSelected = showsQueue
        queueButton.configuration?.baseForegroundColor = showsQueue ? UIColor(white: 0.12, alpha: 1) : UIColor.white.withAlphaComponent(0.5)
        queueButton.configuration?.background.backgroundColor = showsQueue ? UIColor.white.withAlphaComponent(0.5) : .clear
        queueButton.configuration?.background.backgroundInsets = NSDirectionalEdgeInsets(top: 3, leading: max(0, options.bounds.width / 6 - 19), bottom: 3, trailing: max(0, options.bounds.width / 6 - 19))
        queueButton.configuration?.cornerStyle = .capsule
        queueButton.accessibilityValue = showsQueue ? "Shown" : "Hidden"
        queueButton.accessibilityHint = showsQueue ? "Shows episode artwork" : "Shows upcoming episodes"
        queueButton.accessibilityTraits = showsQueue ? [.button, .selected] : .button
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let velocity = queuePan.velocity(in: stage)
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        return showsQueue ? queuePan.location(in: stage).y < queue.view.frame.minY && velocity.y > 0 : velocity.y < 0
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var touched = touch.view
        while let current = touched, current !== stage {
            if current is UIControl { return false }; touched = current.superview
        }
        return true
    }
    private func stopTransition() {
        guard let animator, animator.state == .active else { return }
        queueProgress = panStart + ((showsQueue ? 1 : 0) - panStart) * animator.fractionComplete
        animator.stopAnimation(false); animator.finishAnimation(at: .current); self.animator = nil
    }
    @objc private func panQueue(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began: stopTransition(); panStart = queueProgress
        case .changed:
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            queueProgress = min(1, max(0, panStart - pan.translation(in: stage).y / max(180, stage.bounds.height * 0.6))); layoutStage()
        case .ended:
            let projected = panStart - (pan.translation(in: stage).y + pan.velocity(in: stage).y * 0.15) / max(180, stage.bounds.height * 0.6)
            setQueue(projected > 0.5)
        case .cancelled, .failed: setQueue(showsQueue)
        default: break
        }
    }
    @objc private func panDismiss(_ pan: UIPanGestureRecognizer) {
        if pan.state == .ended, pan.translation(in: view).y > 50 || pan.velocity(in: view).y > 500 { dismiss(animated: true) }
    }
    private func updateScrubbingTime() {
        let position = Double(slider.value)
        slider.accessibilityValue = PodcastUI.time(position)
        elapsed.text = PodcastUI.time(position); remaining.text = "−" + PodcastUI.time(max(0, player.duration - position))
    }
    private func refresh() {
        guard isViewLoaded else { return }
        let episode = player.currentEpisode
        titleLabel.text = episode?.title ?? "Not Playing"
        dateLabel.text = episode.flatMap { $0.publishedAt == .distantPast ? nil : $0.publishedAt.formatted(.dateTime.month(.wide).day()) }
        showLabel.text = player.errorMessage ?? (player.isBuffering ? "Loading Audio…" : nil) ?? library.state.shows[episode?.showID ?? ""]?.title
        showLabel.textColor = player.errorMessage == nil ? UIColor.white.withAlphaComponent(0.5) : .systemRed
        let url = episode?.artworkURL ?? library.state.shows[episode?.showID ?? ""]?.artworkURL
        if artworkID != url || artwork.image == nil {
            artworkID = url; artworkTask?.cancel(); PodcastUI.artwork(url, into: artwork)
            let cached = url.flatMap { PodcastUI.images.object(forKey: $0 as NSURL) }
            backdrop.image = cached
            view.backgroundColor = MusicStyle.artworkColor(cached) ?? UIColor(white: 0.16, alpha: 1)
            if let url, cached == nil {
                artworkTask = Task { [weak self] in
                    let image = await PodcastUI.image(url)
                    guard let self, !Task.isCancelled, self.artworkID == url else { return }
                    self.backdrop.image = image; self.view.backgroundColor = MusicStyle.artworkColor(image) ?? UIColor(white: 0.16, alpha: 1)
                }
            }
        }
        artwork.accessibilityLabel = episode?.isVideo == true ? "Watch Video" : "Episode Artwork"
        if let episode {
            let switchAction = UIAction(title: "Switch to Music", image: UIImage(systemName: "arrow.triangle.swap"), attributes: MediaPlaybackCoordinator.shared.canSwitch ? [] : .disabled) { [weak self] _ in
                self?.queueSwitch.button.sendActions(for: .touchUpInside)
            }
            let extras = UIMenu(options: .displayInline, children: [UIAction(title: "Chapters", image: UIImage(systemName: "list.number")) { [weak self] _ in self?.open(PodcastChaptersViewController()) }, switchAction])
            more.menu = UIMenu(children: PodcastUI.episodeMenu(episode, from: self).children + [extras])
        }
        if !slider.isTracking { slider.maximumValue = Float(max(1, player.duration)); slider.value = Float(player.position); updateScrubbingTime() }
        play.configuration?.image = UIImage(systemName: player.isPlaying || player.isBuffering ? "pause.fill" : "play.fill")
        play.configuration?.showsActivityIndicator = player.isBuffering
        play.accessibilityValue = player.isBuffering ? "Loading Audio" : nil
        play.accessibilityLabel = player.isPlaying || player.isBuffering ? "Pause" : "Play"
        speed.configuration?.title = "\(player.rate.formatted())×"
        speed.accessibilityValue = "\(player.rate.formatted()) times"
        let sleeping = player.sleepAtEpisodeEnd || player.sleepDeadline != nil
        sleep.configuration?.baseForegroundColor = sleeping ? .white : UIColor.white.withAlphaComponent(0.5)
        sleep.accessibilityValue = player.sleepAtEpisodeEnd ? "When Current Episode Ends" : player.sleepDeadline.map { $0.formatted(date: .omitted, time: .shortened) } ?? "Off"
        let settings = library.state.settings
        back.accessibilityLabel = "Skip Back \(Int(settings.skipBack)) Seconds"; forward.accessibilityLabel = "Skip Forward \(Int(settings.skipForward)) Seconds"
        back.configuration?.image = UIImage(systemName: "gobackward.\(Int(settings.skipBack))") ?? UIImage(systemName: "gobackward")
        forward.configuration?.image = UIImage(systemName: "goforward.\(Int(settings.skipForward))") ?? UIImage(systemName: "goforward")
    }
    @objc private func openVideo() {
        guard player.currentEpisode?.isVideo == true else { return }
        let controller = AVPlayerViewController(); controller.player = player.player; controller.allowsPictureInPicturePlayback = true
        present(controller, animated: true)
    }
}
