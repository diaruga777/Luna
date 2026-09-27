import UIKit
import MediaPlayer
import AVKit
import LunaMusicCore

@MainActor
internal final class MusicPlayerViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    private let player = MusicPlaybackController.shared
    private let art = MusicStyle.artwork(corner: 18)
    private let titleLabel = UILabel()
    private let artistLabel = UILabel()
    private let sourceLabel = UILabel()
    private let elapsed = UILabel()
    private let remaining = UILabel()
    private let slider = UISlider()
    private let table = UITableView(frame: .zero, style: .plain)
    private let mode = UISegmentedControl(items: ["Now Playing", "Queue"])
    private var play: UIButton!
    private var shuffle: UIButton!
    private var repeatButton: UIButton!
    private var token: NSObjectProtocol?
    private var timer: Timer?
    private var initialQueue: Bool
    private var artworkHeight: NSLayoutConstraint!
    private var queueHeight: NSLayoutConstraint!
    init(showQueue: Bool) { initialQueue = showQueue; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        view.tintColor = .label
        let scroll = UIScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(scroll)
        let stack = UIStackView(); stack.axis = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false; scroll.addSubview(stack)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor), scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 18), scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor), stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24), stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -48)])
        mode.selectedSegmentIndex = initialQueue ? 1 : 0
        mode.addAction(UIAction { [weak self] _ in self?.updateMode() }, for: .valueChanged)
        stack.addArrangedSubview(mode)
        stack.addArrangedSubview(art)
        artworkHeight = art.heightAnchor.constraint(equalTo: art.widthAnchor); artworkHeight.priority = .defaultHigh; artworkHeight.isActive = true
        titleLabel.font = .preferredFont(forTextStyle: .title2); titleLabel.numberOfLines = 2
        artistLabel.font = .preferredFont(forTextStyle: .title3); artistLabel.textColor = .secondaryLabel
        [titleLabel, artistLabel, sourceLabel, elapsed, remaining].forEach { $0.adjustsFontForContentSizeCategory = true }
        let names = UIStackView(arrangedSubviews: [titleLabel, artistLabel]); names.axis = .vertical; names.spacing = 4
        stack.addArrangedSubview(names)
        shuffle = MusicStyle.button("shuffle", label: "Shuffle") { [weak self] in guard let self else { return }; self.player.setShuffle(!self.player.shuffleEnabled) }
        repeatButton = MusicStyle.button("repeat", label: "Repeat") { [weak self] in self?.player.cycleRepeat() }
        let options = UIStackView(arrangedSubviews: [shuffle, repeatButton]); options.distribution = .fillEqually; options.spacing = 16
        options.heightAnchor.constraint(equalToConstant: 44).isActive = true
        stack.addArrangedSubview(options)
        sourceLabel.font = .preferredFont(forTextStyle: .headline); sourceLabel.numberOfLines = 2; stack.addArrangedSubview(sourceLabel)
        table.backgroundColor = .clear; table.delegate = self; table.dataSource = self; table.rowHeight = 76
        table.register(UITableViewCell.self, forCellReuseIdentifier: "song")
        table.setEditing(true, animated: false); table.allowsSelectionDuringEditing = true
        stack.addArrangedSubview(table); queueHeight = table.heightAnchor.constraint(equalToConstant: 290); queueHeight.priority = .defaultHigh; queueHeight.isActive = true
        slider.accessibilityLabel = "Playback Position"
        slider.addAction(UIAction { [weak self] _ in guard let self else { return }; self.player.seek(to: Double(self.slider.value)) }, for: .touchUpInside)
        slider.addAction(UIAction { [weak self] _ in guard let self else { return }; self.player.seek(to: Double(self.slider.value)) }, for: .touchUpOutside)
        let timeStack = UIStackView(arrangedSubviews: [elapsed, UIView(), remaining]); elapsed.font = .preferredFont(forTextStyle: .caption1); remaining.font = .preferredFont(forTextStyle: .caption1); elapsed.textColor = .secondaryLabel; remaining.textColor = .secondaryLabel
        let timeline = UIStackView(arrangedSubviews: [slider, timeStack]); timeline.axis = .vertical; timeline.spacing = 2; stack.addArrangedSubview(timeline)
        let previous = MusicStyle.button("backward.fill", label: "Previous Song") { [weak self] in self?.player.previous() }
        play = MusicStyle.button("play.fill", label: "Play") { [weak self] in self?.player.togglePlayPause() }
        let next = MusicStyle.button("forward.fill", label: "Next Song") { [weak self] in self?.player.next() }
        [previous, play!, next].forEach { $0.setPreferredSymbolConfiguration(UIImage.SymbolConfiguration(pointSize: 32, weight: .semibold), forImageIn: .normal) }
        let transport = UIStackView(arrangedSubviews: [previous, play, next]); transport.distribution = .fillEqually; transport.heightAnchor.constraint(equalToConstant: 70).isActive = true; stack.addArrangedSubview(transport)
        let volume = MPVolumeView(); volume.showsRouteButton = false; volume.heightAnchor.constraint(equalToConstant: 36).isActive = true; volume.accessibilityLabel = "Volume"; stack.addArrangedSubview(volume)
        let route = AVRoutePickerView(); route.activeTintColor = .systemPink; route.tintColor = .label; route.heightAnchor.constraint(equalToConstant: 44).isActive = true; route.accessibilityLabel = "AirPlay and Audio Output"; stack.addArrangedSubview(route)
        token = NotificationCenter.default.addObserver(forName: .lunaMusicPlaybackChanged, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.updateTime() } }
        updateMode(); refresh()
    }
    deinit { if let token { NotificationCenter.default.removeObserver(token) }; timer?.invalidate() }
    private func updateMode() {
        let isQueue = mode.selectedSegmentIndex == 1
        view.accessibilityIdentifier = isQueue ? "music.playback.queue" : "music.playback.nowPlaying"
        art.isHidden = isQueue; table.isHidden = !isQueue; sourceLabel.isHidden = !isQueue
        table.accessibilityLabel = "Upcoming Songs"
    }
    private func refresh() {
        titleLabel.text = player.nowPlaying?.title ?? "Not Playing"
        artistLabel.text = player.nowPlaying?.artist ?? "Choose music from your library"
        art.image = MusicStyle.image(player.nowPlaying, size: 800) ?? UIImage(systemName: "music.note")
        art.contentMode = player.nowPlaying?.artwork == nil ? .center : .scaleAspectFill
        art.accessibilityLabel = "Album artwork"
        play.setImage(UIImage(systemName: player.isPlaying ? "pause.fill" : "play.fill"), for: .normal)
        play.accessibilityLabel = player.isPlaying ? "Pause" : "Play"
        shuffle.tintColor = player.shuffleEnabled ? .systemPink : .label
        shuffle.accessibilityValue = player.shuffleEnabled ? "On" : "Off"
        repeatButton.tintColor = player.repeatMode == .none ? .label : .systemPink
        repeatButton.setImage(UIImage(systemName: player.repeatMode == .one ? "repeat.1" : "repeat"), for: .normal)
        repeatButton.accessibilityValue = player.repeatMode == .one ? "One Song" : player.repeatMode == .all ? "All Songs" : "Off"
        sourceLabel.text = player.sourcePlaylistName.map { "Continue Playing\nFrom \($0)" } ?? "Continue Playing"
        table.reloadData()
        if upcomingCount == 0 {
            var config = UIContentUnavailableConfiguration.empty(); config.text = "No Upcoming Songs"; config.secondaryText = "Choose a song or add music with Play Next."; config.image = UIImage(systemName: "music.note.list")
            table.backgroundView = UIContentUnavailableView(configuration: config)
        } else { table.backgroundView = nil }
        updateTime()
    }
    private func updateTime() {
        guard !slider.isTracking else { return }
        slider.maximumValue = Float(max(1, player.duration)); slider.value = Float(max(0, player.playbackTime)); slider.isEnabled = player.duration > 0
        elapsed.text = time(player.playbackTime); remaining.text = "−\(time(max(0, player.duration - player.playbackTime)))"
        slider.accessibilityValue = "\(time(player.playbackTime)) of \(time(player.duration))"
    }
    private func time(_ seconds: TimeInterval) -> String { let value = seconds.isFinite ? Int(max(0, seconds)) : 0; return String(format: "%d:%02d", value / 60, value % 60) }
    private var upcomingStart: Int { min(player.queue.count, player.currentIndex + 1) }
    private var upcomingCount: Int { max(0, player.queue.count - upcomingStart) }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { upcomingCount }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = player.queue[upcomingStart + indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "song", for: indexPath)
        var config = cell.defaultContentConfiguration(); config.text = item.title ?? "Unknown Song"; config.secondaryText = item.artist
        config.image = MusicStyle.image(item, size: 100) ?? UIImage(systemName: "music.note"); config.imageProperties.maximumSize = CGSize(width: 48, height: 48); config.imageProperties.cornerRadius = 6; config.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = config; cell.backgroundColor = .clear; cell.showsReorderControl = true; return cell
    }
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }
    func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) { player.moveUpcoming(from: upcomingStart + sourceIndexPath.row, to: upcomingStart + destinationIndexPath.row) }
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) { if editingStyle == .delete { player.removeUpcoming(at: upcomingStart + indexPath.row) } }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let selected = Array(player.queue[(upcomingStart + indexPath.row)...])
        MusicStyle.run(from: self) { try await self.player.play(selected) }
    }
}
