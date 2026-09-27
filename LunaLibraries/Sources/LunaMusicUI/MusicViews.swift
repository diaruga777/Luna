import UIKit
import MediaPlayer
import AVKit
import LunaMusicCore

@MainActor
internal enum MusicStyle {
    static let tint = UIColor.systemPink
    static func font(_ size: CGFloat, weight: UIFont.Weight = .regular) -> UIFont {
        UIFontMetrics(forTextStyle: .body).scaledFont(for: .systemFont(ofSize: size, weight: weight))
    }
    static func plainButton(_ symbol: String, label: String, size: CGFloat = 22, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol)
        configuration.baseForegroundColor = .label
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: size, weight: .semibold)
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = label
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
    static func setSelected(_ selected: Bool, on button: UIButton) {
        button.isSelected = selected
        button.configuration?.baseForegroundColor = selected ? .darkGray : .white
        button.configuration?.background.backgroundColor = UIColor.white.withAlphaComponent(selected ? 0.7 : 0.12)
        button.configuration?.cornerStyle = .capsule
        button.accessibilityTraits = selected ? [.button, .selected] : .button
    }
    static func image(_ item: MPMediaItem?, size: CGFloat = 300) -> UIImage? {
        item?.artwork?.image(at: CGSize(width: size, height: size))
    }
    static func artwork(_ image: UIImage? = nil, corner: CGFloat = 8) -> UIImageView {
        let view = UIImageView(image: image ?? UIImage(systemName: "music.note"))
        view.contentMode = image == nil ? .center : .scaleAspectFill
        view.backgroundColor = .secondarySystemBackground
        view.tintColor = .tertiaryLabel
        view.layer.cornerRadius = corner
        view.clipsToBounds = true
        return view
    }
    static func changeArtwork(_ view: UIImageView, to image: UIImage?, hasArtwork: Bool) {
        let update = {
            view.image = image ?? UIImage(systemName: "music.note")
            view.contentMode = hasArtwork ? .scaleAspectFill : .center
        }
        if view.window != nil && !UIAccessibility.isReduceMotionEnabled {
            UIView.transition(with: view, duration: 0.25,
                              options: [.transitionCrossDissolve, .beginFromCurrentState],
                              animations: update)
        } else { update() }
    }
    static func run(from presenter: UIViewController, _ action: @escaping () async throws -> Void) {
        Task { do { try await action() } catch {
            let alert = UIAlertController(title: "Unable to Play", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            presenter.present(alert, animated: true)
        } }
    }
}

@MainActor
public class MusicScreenViewController: UIViewController {
    let table = UITableView(frame: .zero, style: .plain)
    let mini = MusicMiniPlayer()
    var notificationTokens: [NSObjectProtocol] = []
    var tableTop: NSLayoutConstraint!
    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        view.tintColor = MusicStyle.tint
        table.backgroundColor = .clear
        table.separatorColor = .separator
        table.keyboardDismissMode = .interactive
        table.rowHeight = UITableView.automaticDimension
        table.estimatedRowHeight = 76
        table.translatesAutoresizingMaskIntoConstraints = false
        mini.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(table)
        view.addSubview(mini)
        tableTop = table.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor)
        NSLayoutConstraint.activate([
            tableTop, table.leadingAnchor.constraint(equalTo: view.leadingAnchor), table.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            table.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            mini.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20), mini.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            mini.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8), mini.heightAnchor.constraint(equalToConstant: 48)
        ])
        table.contentInset.bottom = 72
        table.verticalScrollIndicatorInsets.bottom = 72
        mini.onOpen = { [weak self] in self?.presentPlayer(queue: false) }
        observe(.lunaMusicPlaybackChanged) { [weak self] in self?.mini.refresh() }
        mini.refresh()
    }
    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let inset = max(72, view.bounds.maxY - mini.frame.minY + 8)
        if abs(table.contentInset.bottom - inset) > 1 {
            table.contentInset.bottom = inset
            table.verticalScrollIndicatorInsets.bottom = inset
        }
    }
    func observe(_ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        notificationTokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
            Task { @MainActor in action() }
        })
    }
    deinit { notificationTokens.forEach(NotificationCenter.default.removeObserver) }
    func presentPlayer(queue: Bool) {
        view.endEditing(true)
        let controller = MusicPlayerViewController(showQueue: queue)
        controller.modalPresentationStyle = .fullScreen
        if !UIAccessibility.isReduceMotionEnabled {
            controller.preferredTransition = .zoom(options: nil) { [weak self] _ in self?.mini }
        }
        present(controller, animated: true)
    }
    func songMenu(_ item: MPMediaItem) -> UIMenu {
        UIMenu(children: [
            UIAction(title: "Play", image: UIImage(systemName: "play.fill")) { [weak self] _ in
                guard let self else { return }
                MusicStyle.run(from: self) { try await MusicPlaybackController.shared.playSong(item) }
            },
            UIMenu(title: "Add to Playlist", image: UIImage(systemName: "text.badge.plus"), children: MusicLibraryController.shared.playlists.map { playlist in
                UIAction(title: playlist.name ?? "Playlist") { [weak self] _ in
                    guard let self else { return }
                    MusicStyle.run(from: self) { try await MusicLibraryController.shared.add([item], to: playlist) }
                }
            }),
            UIAction(title: "Play Next", image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { _ in MusicPlaybackController.shared.playNext(item) },
            UIAction(title: "Play Last", image: UIImage(systemName: "text.line.last.and.arrowtriangle.forward")) { _ in MusicPlaybackController.shared.playLater(item) }
        ])
    }
    func configureSong(_ cell: UITableViewCell, item: MPMediaItem) {
        var config = cell.defaultContentConfiguration()
        config.text = item.title ?? "Unknown Song"
        config.secondaryText = item.artist ?? "Unknown Artist"
        config.image = MusicStyle.image(item, size: 100) ?? UIImage(systemName: "music.note")
        config.imageProperties.maximumSize = CGSize(width: 48, height: 48)
        config.imageProperties.cornerRadius = 6
        config.textProperties.font = MusicStyle.font(22)
        config.secondaryTextProperties.font = MusicStyle.font(19)
        config.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 5, leading: 20, bottom: 5, trailing: 20)
        config.imageToTextPadding = 12
        config.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = config
        let more = UIButton(type: .system)
        more.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        more.tintColor = .secondaryLabel
        more.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        more.menu = songMenu(item)
        more.showsMenuAsPrimaryAction = true
        more.accessibilityLabel = "More options for \(item.title ?? "song")"
        cell.accessoryView = more
        cell.backgroundColor = .clear
    }
}

@MainActor
internal final class MusicMiniPlayer: UIVisualEffectView {
    var onOpen: (() -> Void)?
    let art = MusicStyle.artwork()
    let titleLabel = UILabel()
    let artistLabel = UILabel()
    private var play: UIButton!
    private var artworkID: UInt64?
    override init(effect: UIVisualEffect? = nil) {
        let background: UIVisualEffect
        if #available(iOS 26, *) {
            let glass = UIGlassEffect(style: .regular)
            glass.isInteractive = true
            background = glass
        } else { background = UIBlurEffect(style: .systemChromeMaterial) }
        super.init(effect: effect ?? background)
        layer.cornerRadius = 30
        clipsToBounds = true
        titleLabel.font = MusicStyle.font(17, weight: .semibold)
        artistLabel.font = MusicStyle.font(17)
        artistLabel.textColor = .secondaryLabel
        [titleLabel, artistLabel].forEach { $0.adjustsFontForContentSizeCategory = true }
        let labels = UIStackView(arrangedSubviews: [titleLabel, artistLabel]); labels.axis = .vertical
        let open = UIButton(type: .custom)
        open.addAction(UIAction { [weak self] _ in self?.onOpen?() }, for: .touchUpInside)
        open.accessibilityLabel = "Open Now Playing"
        play = MusicStyle.plainButton("play.fill", label: "Play", size: 18) { MusicPlaybackController.shared.togglePlayPause() }
        let next = MusicStyle.plainButton("forward.fill", label: "Next Song", size: 16) { MusicPlaybackController.shared.next() }
        play.tintColor = .label; next.tintColor = .label
        let stack = UIStackView(arrangedSubviews: [art, labels, play, next]); stack.spacing = 8; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(stack)
        open.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(open)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6), stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            art.widthAnchor.constraint(equalToConstant: 32), art.heightAnchor.constraint(equalTo: art.widthAnchor), play.widthAnchor.constraint(equalToConstant: 40), next.widthAnchor.constraint(equalToConstant: 40),
            open.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), open.topAnchor.constraint(equalTo: contentView.topAnchor), open.bottomAnchor.constraint(equalTo: contentView.bottomAnchor), open.trailingAnchor.constraint(equalTo: play.leadingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() {
        let player = MusicPlaybackController.shared
        titleLabel.text = player.nowPlaying?.title ?? "Not Playing"
        artistLabel.text = player.nowPlaying?.artist ?? "Choose a song from your library"
        if artworkID != player.nowPlaying?.persistentID {
            MusicStyle.changeArtwork(art, to: MusicStyle.image(player.nowPlaying, size: 100), hasArtwork: player.nowPlaying?.artwork != nil)
            artworkID = player.nowPlaying?.persistentID
        }
        play.configuration?.image = UIImage(systemName: player.isPlaying ? "pause.fill" : "play.fill")
        play.accessibilityLabel = player.isPlaying ? "Pause" : "Play"
    }
}
