import UIKit
import MediaPlayer
import AVKit
import AVFAudio
import LunaMusicCore

/// The upper stage changes between artwork and queue. Playback controls never
/// participate in scrolling, so volume stays reachable on every screen size.
@MainActor
internal final class MusicPlayerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate {
    private let player = MusicPlaybackController.shared
    private let backdrop = UIImageView()
    private let blur = UIVisualEffectView(effect: UIBlurEffect(style: .dark))
    private let shade = UIView()
    private let stage = UIView()
    private let grabber = UIView()
    private let close = UIButton(type: .custom)
    private let volumeLow = UIImageView(image: UIImage(systemName: "speaker.fill"))
    private let volumeHigh = UIImageView(image: UIImage(systemName: "speaker.wave.3.fill"))
    private let art = MusicStyle.artwork(corner: 10)
    private let names = UIStackView()
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let sourceLabel = UILabel()
    private let elapsed = UILabel()
    private let remaining = UILabel()
    private let slider = UISlider()
    private let table = UITableView(frame: .zero, style: .plain)
    private let options = UIStackView()
    private let transport = UIStackView()
    private let volume = MPVolumeView()
    private let route = AVRoutePickerView()
    private let outputLabel = UILabel()
    private let more = UIButton(type: .system)
    private var play: UIButton!
    private var shuffle: UIButton!
    private var repeatButton: UIButton!
    private var queueButton: UIButton!
    private var token: NSObjectProtocol?
    private var routeToken: NSObjectProtocol?
    private var timer: Timer?
    private var showsQueue: Bool
    private var artworkID: MusicID?
    private var queueProgress: CGFloat
    private var panStart: CGFloat = 0
    private var animator: UIViewPropertyAnimator?
    private lazy var queuePan = UIPanGestureRecognizer(target: self, action: #selector(panQueue(_:)))

    init(showQueue: Bool) {
        showsQueue = showQueue
        queueProgress = showQueue ? 1 : 0
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor(white: 0.2, alpha: 1)
        view.tintColor = .white
        backdrop.contentMode = .scaleAspectFill
        backdrop.alpha = 0.15
        backdrop.clipsToBounds = true
        shade.backgroundColor = UIColor.black.withAlphaComponent(0.25)
        [backdrop, blur, shade, stage, slider, elapsed, remaining, transport, volume, volumeLow, volumeHigh, route, grabber, close].forEach(view.addSubview)
        [art, names, more, options, sourceLabel, table].forEach(stage.addSubview)
        stage.clipsToBounds = true
        grabber.backgroundColor = UIColor.white.withAlphaComponent(0.4)
        grabber.layer.cornerRadius = 2
        close.accessibilityLabel = "Close Now Playing"
        close.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        for image in [volumeLow, volumeHigh] {
            image.tintColor = UIColor.white.withAlphaComponent(0.55)
            image.contentMode = .scaleAspectFit
        }
        titleLabel.font = MusicStyle.font(20, weight: .semibold)
        artistLabel.font = MusicStyle.font(20)
        artistLabel.textColor = UIColor.white.withAlphaComponent(0.65)
        titleLabel.lineBreakMode = .byTruncatingTail
        artistLabel.lineBreakMode = .byTruncatingTail
        names.axis = .vertical
        names.spacing = 2
        names.addArrangedSubview(titleLabel)
        names.addArrangedSubview(artistLabel)
        [titleLabel, artistLabel, sourceLabel, elapsed, remaining].forEach { $0.adjustsFontForContentSizeCategory = true }

        more.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)), for: .normal)
        more.tintColor = .white
        more.accessibilityLabel = "Song Options"
        more.showsMenuAsPrimaryAction = true
        outputLabel.font = MusicStyle.font(17, weight: .semibold)
        outputLabel.textColor = UIColor.white.withAlphaComponent(0.65)
        outputLabel.textAlignment = .center
        outputLabel.lineBreakMode = .byTruncatingTail
        view.addSubview(outputLabel)
        volume.setVolumeThumbImage(UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }, for: .normal)

        shuffle = MusicStyle.plainButton("shuffle", label: "Shuffle") { [weak self] in
            guard let self else { return }
            self.player.setShuffle(!self.player.shuffleEnabled)
            self.refresh()
        }
        repeatButton = MusicStyle.plainButton("repeat", label: "Repeat") { [weak self] in self?.player.cycleRepeat() }
        options.addArrangedSubview(shuffle)
        options.addArrangedSubview(repeatButton)
        options.distribution = .fillEqually
        options.spacing = 12
        sourceLabel.font = MusicStyle.font(22, weight: .semibold)
        sourceLabel.numberOfLines = 2
        table.backgroundColor = .clear
        table.delegate = self
        table.dataSource = self
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 74
        table.separatorStyle = .none
        table.contentInsetAdjustmentBehavior = .never
        table.register(UITableViewCell.self, forCellReuseIdentifier: "song")
        table.setEditing(true, animated: false)
        table.allowsSelectionDuringEditing = true
        table.accessibilityLabel = "Upcoming Songs"

        slider.accessibilityLabel = "Playback Position"
        slider.minimumTrackTintColor = UIColor.white.withAlphaComponent(0.7)
        slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.25)
        let thumb = UIGraphicsImageRenderer(size: CGSize(width: 3, height: 3)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
        }
        slider.setThumbImage(thumb, for: .normal)
        slider.addAction(UIAction { [weak self] _ in
            guard let self else { return }; self.player.seek(to: Double(self.slider.value))
        }, for: [.touchUpInside, .touchUpOutside])
        for label in [elapsed, remaining] {
            label.font = MusicStyle.font(13, weight: .medium)
            label.textColor = UIColor.white.withAlphaComponent(0.5)
        }
        remaining.textAlignment = .right
        let previous = MusicStyle.plainButton("backward.fill", label: "Previous Song", size: 24) { [weak self] in MediaPlaybackCoordinator.shared.skip(.backward) }
        play = MusicStyle.plainButton("play.fill", label: "Play", size: 34) { [weak self] in self?.player.togglePlayPause() }
        let next = MusicStyle.plainButton("forward.fill", label: "Next Song", size: 24) { [weak self] in MediaPlaybackCoordinator.shared.skip(.forward) }
        [previous, play!, next].forEach { $0.configuration?.baseForegroundColor = .white; transport.addArrangedSubview($0) }
        transport.distribution = .fillEqually
        volume.showsRouteButton = false
        volume.tintColor = UIColor.white.withAlphaComponent(0.7)
        volume.accessibilityIdentifier = "music.playback.volume"
        volume.accessibilityLabel = "Volume"
        route.activeTintColor = .white
        route.tintColor = .white
        route.accessibilityLabel = "AirPlay and Audio Output"
        queueButton = MusicStyle.plainButton("list.bullet", label: "Queue") { [weak self] in
            guard let self else { return }; self.setQueue(!self.showsQueue)
        }
        queueButton.accessibilityIdentifier = "music.playback.queueButton"
        view.addSubview(queueButton)
        queuePan.delegate = self
        stage.addGestureRecognizer(queuePan)
        stage.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Show Queue", actionHandler: { [weak self] _ in
            self?.setQueue(true); return true
        })]
        token = NotificationCenter.default.addObserver(forName: .lunaMusicPlaybackChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        routeToken = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.updateOutputName() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.updateTime() } }
        refresh()
        updateQueueAccessibility()
    }
    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    deinit {
        if let token { NotificationCenter.default.removeObserver(token) }
        if let routeToken { NotificationCenter.default.removeObserver(routeToken) }
        timer?.invalidate()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backdrop.frame = view.bounds.insetBy(dx: -60, dy: -60)
        blur.frame = view.bounds
        shade.frame = view.bounds
        let safe = view.safeAreaInsets
        let landscape = view.bounds.width > view.bounds.height
        let width = min(560, landscape ? view.bounds.width * 0.44 : view.bounds.width - 64)
        let left = landscape ? view.bounds.width - width - max(safe.right, 32) : (view.bounds.width - width) / 2
        let top = max(safe.top + 24, 40)
        let bottom = view.bounds.height - max(safe.bottom, 12)
        let height = bottom - top
        // Reserve a fixed lower region; the artwork absorbs changes in height.
        let controlsHeight = landscape ? height : min(286, height * 0.39)
        let timelineY = bottom - controlsHeight
        stage.frame = landscape
            ? CGRect(x: max(safe.left, 32), y: top, width: view.bounds.width * 0.4 - 32, height: max(0, height))
            : CGRect(x: left, y: top, width: width, height: max(0, timelineY - top - 12))
        grabber.frame = CGRect(x: view.bounds.midX - 30, y: max(12, safe.top + 8), width: 60, height: 4)
        close.frame = CGRect(x: view.bounds.midX - 50, y: max(0, safe.top - 12), width: 100, height: 44)
        slider.frame = CGRect(x: left, y: timelineY, width: width, height: 24)
        elapsed.frame = CGRect(x: left, y: timelineY + 25, width: width / 2, height: 20)
        remaining.frame = CGRect(x: left + width / 2, y: timelineY + 25, width: width / 2, height: 20)
        transport.frame = CGRect(x: left, y: timelineY + controlsHeight * 0.23, width: width, height: controlsHeight * 0.34)
        volume.frame = CGRect(x: left + 24, y: bottom - 100, width: width - 56, height: 32)
        volumeLow.frame = CGRect(x: left, y: bottom - 96, width: 12, height: 18)
        volumeHigh.frame = CGRect(x: left + width - 22, y: bottom - 96, width: 22, height: 18)
        route.frame = CGRect(x: view.bounds.midX - 24, y: bottom - 66, width: 48, height: 44)
        queueButton.frame = CGRect(x: left + width * 0.84 - 22, y: bottom - 66, width: 44, height: 44)
        outputLabel.frame = CGRect(x: left, y: bottom - 22, width: width, height: 24)
        layoutStage()
    }

    private func layoutStage() {
        let width = stage.bounds.width
        let height = stage.bounds.height
        let namesHeight = max(54, titleLabel.font.lineHeight + artistLabel.font.lineHeight + 2)
        let side = max(0, min(width * (player.isPlaying ? 1 : 0.77), height - namesHeight - 38))
        let expandedArt = CGRect(x: (width - side) / 2, y: max(0, (height - namesHeight - 24 - side) / 2), width: side, height: side)
        let compactArt = CGRect(x: 0, y: 0, width: 72, height: 72)
        let expandedNames = CGRect(x: 0, y: height - namesHeight, width: max(0, width - 52), height: namesHeight)
        let compactNames = CGRect(x: 84, y: max(0, (72 - namesHeight) / 2), width: max(0, width - 84 - 44), height: namesHeight)
        func mix(_ start: CGRect, _ end: CGRect) -> CGRect {
            CGRect(x: start.minX + (end.minX - start.minX) * queueProgress,
                   y: start.minY + (end.minY - start.minY) * queueProgress,
                   width: start.width + (end.width - start.width) * queueProgress,
                   height: start.height + (end.height - start.height) * queueProgress)
        }
        art.frame = mix(expandedArt, compactArt)
        names.frame = mix(expandedNames, compactNames)
        more.frame = CGRect(x: width - 44, y: names.frame.midY - 22, width: 44, height: 44)
        // Never assign frame while a nonidentity transform is installed. UIKit
        // interprets that frame in transformed coordinates, moving hit regions
        // over the title and artwork on subsequent layout passes.
        for child in [options, sourceLabel, table] { child.transform = .identity }
        let optionsY = max(86, compactNames.maxY + 14)
        options.frame = CGRect(x: 0, y: optionsY, width: width, height: 38)
        let sourceHeight = sourceLabel.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        sourceLabel.frame = CGRect(x: 0, y: options.frame.maxY + 20, width: width, height: sourceHeight)
        table.frame = CGRect(x: 0, y: sourceLabel.frame.maxY + 12, width: width, height: max(0, height - sourceLabel.frame.maxY - 12))
        for child in [options, sourceLabel, table] {
            child.alpha = queueProgress
            child.frame.origin.y += (1 - queueProgress) * 48
            child.isUserInteractionEnabled = showsQueue
            child.accessibilityElementsHidden = !showsQueue
        }
    }

    private func updateQueueAccessibility() {
        view.accessibilityIdentifier = showsQueue ? "music.playback.queue" : "music.playback.nowPlaying"
        MusicStyle.setSelected(showsQueue, on: queueButton)
        queueButton.configuration?.background.backgroundInsets = NSDirectionalEdgeInsets(top: 3, leading: 3, bottom: 3, trailing: 3)
        if !showsQueue { queueButton.configuration?.background.backgroundColor = .clear }
        queueButton.accessibilityValue = showsQueue ? "Shown" : "Hidden"
        queueButton.accessibilityHint = showsQueue ? "Shows album artwork" : "Shows upcoming songs"
    }

    private func setQueue(_ show: Bool, animated: Bool = true) {
        stopTransition()
        showsQueue = show
        updateQueueAccessibility()
        panStart = queueProgress
        let changes = {
            self.queueProgress = show ? 1 : 0
            self.layoutStage()
        }
        guard animated, !UIAccessibility.isReduceMotionEnabled else { changes(); return }
        let animation = UIViewPropertyAnimator(duration: 0.42, dampingRatio: 0.88, animations: changes)
        animator = animation
        animation.startAnimation()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === queuePan else { return true }
        let velocity = queuePan.velocity(in: stage)
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        // Let the queue own its scrolling/reordering. Pull down on its header to
        // return to artwork; an upward pull anywhere in artwork reveals it.
        if showsQueue { return queuePan.location(in: stage).y < table.frame.minY && velocity.y > 0 }
        return velocity.y < 0
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === queuePan else { return true }
        var touched = touch.view
        while let current = touched, current !== stage {
            if current is UIControl { return false }
            touched = current.superview
        }
        return true
    }

    private func stopTransition() {
        guard let animator, animator.state == .active else { return }
        let fraction = animator.fractionComplete
        queueProgress = panStart + ((showsQueue ? 1 : 0) - panStart) * fraction
        animator.stopAnimation(false)
        animator.finishAnimation(at: .current)
        self.animator = nil
    }

    @objc private func panQueue(_ pan: UIPanGestureRecognizer) {
        switch pan.state {
        case .began:
            stopTransition()
            panStart = queueProgress
        case .changed:
            guard !UIAccessibility.isReduceMotionEnabled else { return }
            queueProgress = min(1, max(0, panStart - pan.translation(in: stage).y / max(180, stage.bounds.height * 0.6)))
            layoutStage()
        case .ended:
            let projected = panStart - (pan.translation(in: stage).y + pan.velocity(in: stage).y * 0.15) / max(180, stage.bounds.height * 0.6)
            setQueue(projected > 0.5)
        case .cancelled, .failed: setQueue(showsQueue)
        default: break
        }
    }

    private func refresh() {
        titleLabel.text = player.nowPlaying?.title ?? "Not Playing"
        artistLabel.text = player.errorMessage ?? player.nowPlaying?.artist ?? "Choose music from your library"
        if artworkID != player.nowPlaying?.persistentID {
            let image = MusicStyle.image(player.nowPlaying, size: 800)
            view.backgroundColor = MusicStyle.artworkColor(image) ?? UIColor(white: 0.2, alpha: 1)
            MusicStyle.changeArtwork(art, to: image, hasArtwork: image != nil)
            MusicStyle.changeArtwork(backdrop, to: image, hasArtwork: image != nil)
            artworkID = player.nowPlaying?.persistentID
        }
        art.accessibilityLabel = "Album artwork"
        play.configuration?.image = UIImage(systemName: (player.isPlaying || player.isBuffering) ? "pause.fill" : "play.fill")
        play.accessibilityLabel = (player.isPlaying || player.isBuffering) ? "Pause" : "Play"
        MusicStyle.setSelected(player.shuffleEnabled, on: shuffle)
        shuffle.accessibilityValue = player.shuffleEnabled ? "On" : "Off"
        MusicStyle.setSelected(player.repeatMode != .none, on: repeatButton)
        repeatButton.configuration?.image = UIImage(systemName: player.repeatMode == .one ? "repeat.1" : "repeat")
        repeatButton.accessibilityValue = player.repeatMode == .one ? "One Song" : player.repeatMode == .all ? "All Songs" : "Off"
        let source = NSMutableAttributedString(string: "Continue Playing", attributes: [.font: MusicStyle.font(22, weight: .semibold), .foregroundColor: UIColor.white])
        if let name = player.sourcePlaylistName {
            source.append(NSAttributedString(string: "\nFrom \(name)", attributes: [.font: MusicStyle.font(19), .foregroundColor: UIColor.white.withAlphaComponent(0.6)]))
        }
        sourceLabel.attributedText = source
        updateOutputName()
        more.isEnabled = player.nowPlaying != nil
        if let item = player.nowPlaying {
            more.menu = UIMenu(children: [
                UIMenu(title: "Add to Playlist", image: UIImage(systemName: "text.badge.plus"), children: MusicLibraryController.shared.playlists.filter { $0.source == item.source && !$0.playlistAttributes.contains(.smart) && !$0.playlistAttributes.contains(.genius) }.map { playlist in
                    UIAction(title: playlist.name ?? "Playlist") { [weak self] _ in
                        guard let self else { return }
                        MusicStyle.run(from: self, errorTitle: "Unable to Add Songs") { try await MusicLibraryController.shared.add([item], to: playlist) }
                    }
                }),
                UIAction(title: "Play Next", image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { _ in MusicPlaybackController.shared.playNext(item) }
            ] + (item.source == .vault ? [UIAction(title: VaultMusicController.shared.isCached(item) ? "Remove Download" : "Download", image: UIImage(systemName: "arrow.down.circle")) { [weak self] _ in
                guard let self else { return }
                MusicStyle.run(from: self, errorTitle: "Download Unavailable") {
                    if VaultMusicController.shared.isCached(item) { try await VaultMusicController.shared.removeCachedSong(item) }
                    else { try VaultMusicController.shared.cacheSongs([item]) }
                }
            }] : []))
        }
        table.reloadData()
        if upcomingCount == 0 {
            let empty = UIView()
            let label = UILabel()
            label.font = MusicStyle.font(20)
            label.textColor = UIColor.white.withAlphaComponent(0.55)
            label.textAlignment = .center
            label.numberOfLines = 0
            if player.repeatMode == .one { label.text = "Repeating Song" }
            else if player.repeatMode == .all && !player.queue.isEmpty { label.text = "Repeating \(player.queue.count) Songs" }
            else { label.text = "No Upcoming Songs" }
            label.translatesAutoresizingMaskIntoConstraints = false
            empty.addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: empty.topAnchor, constant: 24),
                label.leadingAnchor.constraint(equalTo: empty.leadingAnchor, constant: 12),
                label.trailingAnchor.constraint(equalTo: empty.trailingAnchor, constant: -12)
            ])
            table.backgroundView = empty
        } else { table.backgroundView = nil }
        view.setNeedsLayout()
        updateTime()
    }
    private func updateOutputName() {
        outputLabel.text = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: ", ")
    }
    private func updateTime() {
        guard !slider.isTracking else { return }
        slider.maximumValue = Float(max(1, player.duration))
        slider.value = Float(max(0, player.playbackTime))
        slider.isEnabled = player.duration > 0
        elapsed.text = time(player.playbackTime)
        remaining.text = "−\(time(max(0, player.duration - player.playbackTime)))"
        slider.accessibilityValue = "\(time(player.playbackTime)) of \(time(player.duration))"
    }
    private func time(_ seconds: TimeInterval) -> String {
        let value = seconds.isFinite ? Int(max(0, seconds)) : 0
        return String(format: "%d:%02d", value / 60, value % 60)
    }
    private var upcomingStart: Int { min(player.queue.count, player.currentIndex + 1) }
    private var upcomingCount: Int { max(0, player.queue.count - upcomingStart) }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { upcomingCount }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = player.queue[upcomingStart + indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "song", for: indexPath)
        var config = cell.defaultContentConfiguration()
        config.text = item.title ?? "Unknown Song"
        config.secondaryText = item.artist
        config.textProperties.font = MusicStyle.font(20)
        config.secondaryTextProperties.font = MusicStyle.font(17)
        config.image = MusicStyle.image(item, size: 100) ?? UIImage(systemName: "music.note")
        config.imageProperties.maximumSize = CGSize(width: 48, height: 48)
        config.imageProperties.cornerRadius = 5
        config.textProperties.numberOfLines = 1
        config.secondaryTextProperties.numberOfLines = 1
        config.directionalLayoutMargins.top = 12
        config.directionalLayoutMargins.bottom = 12
        config.directionalLayoutMargins.leading = 0
        config.imageToTextPadding = 12
        config.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = config
        cell.backgroundColor = .clear
        cell.showsReorderControl = true
        return cell
    }
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }
    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { .none }
    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }
    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        player.moveUpcoming(from: upcomingStart + sourceIndexPath.row, to: upcomingStart + destinationIndexPath.row)
    }
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let queueIndex = upcomingStart + indexPath.row
        let itemID = player.queue[queueIndex].persistentID
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: [UIAction(title: "Remove from Queue", image: UIImage(systemName: "minus.circle"), attributes: .destructive) { _ in
                guard let self, self.player.queue.indices.contains(queueIndex), self.player.queue[queueIndex].persistentID == itemID else { return }
                self.player.removeUpcoming(at: queueIndex)
            }])
        })
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let selected = Array(player.queue[(upcomingStart + indexPath.row)...])
        MusicStyle.run(from: self) { try await self.player.play(selected) }
    }
}
