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
        controller.modalPresentationStyle = .fullScreen; present(controller, animated: true)
    }
}
@MainActor final class PodcastPlayerViewController: UIViewController {
    private let player = PodcastPlaybackController.shared
    private let artwork = UIImageView()
    private let titleLabel = UILabel(), showLabel = UILabel(), elapsed = UILabel(), remaining = UILabel()
    private let slider = UISlider()
    private var play: UIButton!, speed: UIButton!, sleep: UIButton!, back: UIButton!, forward: UIButton!
    private var subscriptions = Set<AnyCancellable>()
    private let showQueue: Bool
    private var queueSwitch: MediaPlayerQueueSwitch!
    private var artworkID: String?
    init(showQueue: Bool) { self.showQueue = showQueue; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.backgroundColor = .systemBackground; view.tintColor = .systemPurple
        title = "Now Playing"; navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "chevron.down"), primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.leftBarButtonItem?.accessibilityLabel = "Close Now Playing"
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"))
        artwork.layer.cornerRadius = 16; artwork.clipsToBounds = true; artwork.backgroundColor = .secondarySystemBackground; artwork.isUserInteractionEnabled = true
        artwork.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openVideo)))
        titleLabel.font = .preferredFont(forTextStyle: .title2); titleLabel.numberOfLines = 2
        showLabel.font = .preferredFont(forTextStyle: .body); showLabel.textColor = .secondaryLabel; showLabel.numberOfLines = 2
        for label in [titleLabel, showLabel, elapsed, remaining] { label.adjustsFontForContentSizeCategory = true }
        elapsed.font = .preferredFont(forTextStyle: .caption1); remaining.font = elapsed.font; remaining.textAlignment = .right
        slider.accessibilityLabel = "Episode Position"; slider.addAction(UIAction { [weak self] _ in guard let self else { return }; player.seek(to: Double(slider.value)) }, for: .valueChanged)
        let times = UIStackView(arrangedSubviews: [elapsed, remaining]); times.distribution = .fillEqually
        back = MusicStyle.plainButton("gobackward.15", label: "Skip Back", size: 32) { MediaPlaybackCoordinator.shared.skip(.backward) }
        play = MusicStyle.plainButton("play.fill", label: "Play", size: 44) { [weak self] in self?.player.toggle() }
        forward = MusicStyle.plainButton("goforward.30", label: "Skip Forward", size: 32) { MediaPlaybackCoordinator.shared.skip(.forward) }
        let transport = UIStackView(arrangedSubviews: [back, play, forward]); transport.distribution = .equalSpacing; transport.alignment = .center
        speed = UIButton(configuration: .plain()); speed.showsMenuAsPrimaryAction = true; speed.accessibilityLabel = "Playback Speed"
        speed.menu = UIMenu(title: "Playback Speed", children: [Float(0.5), 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3].map { value in UIAction(title: "\(value)×") { [weak self] _ in self?.player.setRate(value) } })
        sleep = MusicStyle.plainButton("moon", label: "Sleep Timer") {}; sleep.showsMenuAsPrimaryAction = true
        sleep.menu = UIMenu(title: "Sleep Timer", children: [UIAction(title: "Off") { [weak self] _ in self?.player.setSleepTimer(minutes: nil) }] + [5, 10, 15, 30, 45, 60].map { minutes in UIAction(title: "\(minutes) minutes") { [weak self] _ in self?.player.setSleepTimer(minutes: minutes) } } + [UIAction(title: "When Current Episode Ends") { [weak self] _ in self?.player.setSleepTimer(minutes: nil, endOfEpisode: true) }])
        let transcript = MusicStyle.plainButton("quote.bubble", label: "Transcript") { [weak self] in self?.navigationController?.pushViewController(PodcastTranscriptViewController(), animated: true) }
        let chapters = MusicStyle.plainButton("list.number", label: "Chapters") { [weak self] in self?.navigationController?.pushViewController(PodcastChaptersViewController(), animated: true) }
        let queue = MusicStyle.plainButton("list.bullet", label: "Playing Next") { [weak self] in self?.navigationController?.pushViewController(PodcastQueueViewController(), animated: true) }
        queueSwitch = MediaPlayerQueueSwitch(owner: self, surface: .podcasts, showsQueue: { [weak self] in
            self?.navigationController?.topViewController is PodcastQueueViewController
        })
        let route = AVRoutePickerView(); route.tintColor = .label
        let options = UIStackView(arrangedSubviews: [speed, sleep, transcript, chapters, queue, route]); options.distribution = .fillEqually
        let volume = MPVolumeView(); volume.showsRouteButton = false
        let controls = UIStackView(arrangedSubviews: [titleLabel, showLabel, slider, times, transport, volume, options, queueSwitch.button]); controls.axis = .vertical; controls.spacing = 12
        let artContainer = UIView(); artContainer.addSubview(artwork); artwork.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView(arrangedSubviews: [artContainer, controls]); stack.axis = .vertical; stack.spacing = 24; stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        let artHeight = artwork.heightAnchor.constraint(equalTo: artContainer.heightAnchor); artHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24), stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24), stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16), artwork.centerXAnchor.constraint(equalTo: artContainer.centerXAnchor), artwork.centerYAnchor.constraint(equalTo: artContainer.centerYAnchor), artwork.widthAnchor.constraint(equalTo: artwork.heightAnchor), artwork.widthAnchor.constraint(lessThanOrEqualTo: artContainer.widthAnchor), artwork.heightAnchor.constraint(lessThanOrEqualTo: artContainer.heightAnchor), artHeight, artContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 60), transport.heightAnchor.constraint(greaterThanOrEqualToConstant: 64), volume.heightAnchor.constraint(equalToConstant: 32), options.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
        player.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.refresh() } }.store(in: &subscriptions)
        refresh()
        if showQueue { DispatchQueue.main.async { [weak self] in self?.navigationController?.pushViewController(PodcastQueueViewController(), animated: false) } }
    }
    private func refresh() {
        guard isViewLoaded else { return }
        let episode = player.currentEpisode
        titleLabel.text = episode?.title ?? "Not Playing"
        showLabel.text = player.errorMessage ?? (player.isBuffering ? "Loading Audio…" : nil) ?? PodcastLibraryController.shared.state.shows[episode?.showID ?? ""]?.title
        showLabel.textColor = player.errorMessage == nil ? .secondaryLabel : .systemRed
        if artworkID != episode?.id {
            artworkID = episode?.id; PodcastUI.artwork(episode?.artworkURL ?? PodcastLibraryController.shared.state.shows[episode?.showID ?? ""]?.artworkURL, into: artwork)
            artwork.accessibilityLabel = episode?.isVideo == true ? "Watch Video" : "Episode Artwork"
            navigationItem.rightBarButtonItem?.menu = episode.map { PodcastUI.episodeMenu($0, from: self) }
        }
        if !slider.isTracking { slider.maximumValue = Float(max(1, player.duration)); slider.value = Float(player.position) }
        slider.accessibilityValue = PodcastUI.time(player.position)
        elapsed.text = PodcastUI.time(player.position); remaining.text = "−" + PodcastUI.time(max(0, player.duration - player.position))
        play.configuration?.image = UIImage(systemName: player.isPlaying || player.isBuffering ? "pause.fill" : "play.fill")
        play.configuration?.showsActivityIndicator = player.isBuffering
        play.accessibilityValue = player.isBuffering ? "Loading Audio" : nil
        play.accessibilityLabel = player.isPlaying || player.isBuffering ? "Pause" : "Play"
        speed.configuration?.title = "\(player.rate)×"
        sleep.configuration?.image = UIImage(systemName: player.sleepAtEpisodeEnd || player.sleepDeadline != nil ? "moon.fill" : "moon")
        let settings = PodcastLibraryController.shared.state.settings
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
