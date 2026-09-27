import UIKit
import MediaPlayer
import AVKit
import LunaMusicCore

@MainActor
internal enum MusicStyle {
    static let tint = UIColor.systemPink
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
    static func button(_ symbol: String, label: String, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: symbol), for: .normal)
        button.accessibilityLabel = label
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
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
            table.bottomAnchor.constraint(equalTo: mini.topAnchor, constant: -6),
            mini.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16), mini.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            mini.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8), mini.heightAnchor.constraint(equalToConstant: 64)
        ])
        mini.onOpen = { [weak self] in self?.presentPlayer(queue: false) }
        observe(.lunaMusicPlaybackChanged) { [weak self] in self?.mini.refresh() }
        mini.refresh()
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
        controller.modalPresentationStyle = .pageSheet
        if let sheet = controller.sheetPresentationController { sheet.detents = [.large()]; sheet.prefersGrabberVisible = true }
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
        config.imageProperties.maximumSize = CGSize(width: 52, height: 52)
        config.imageProperties.cornerRadius = 6
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
    override init(effect: UIVisualEffect? = nil) {
        super.init(effect: effect ?? UIBlurEffect(style: .systemChromeMaterial))
        layer.cornerRadius = 30
        clipsToBounds = true
        layer.borderColor = UIColor.white.withAlphaComponent(0.12).cgColor
        layer.borderWidth = 0.5
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        artistLabel.font = .preferredFont(forTextStyle: .subheadline)
        artistLabel.textColor = .secondaryLabel
        [titleLabel, artistLabel].forEach { $0.adjustsFontForContentSizeCategory = true }
        let labels = UIStackView(arrangedSubviews: [titleLabel, artistLabel]); labels.axis = .vertical
        let open = UIButton(type: .custom)
        open.addAction(UIAction { [weak self] _ in self?.onOpen?() }, for: .touchUpInside)
        open.accessibilityLabel = "Open Now Playing"
        play = MusicStyle.button("play.fill", label: "Play") { MusicPlaybackController.shared.togglePlayPause() }
        let next = MusicStyle.button("forward.fill", label: "Next Song") { MusicPlaybackController.shared.next() }
        play.tintColor = .label; next.tintColor = .label
        let stack = UIStackView(arrangedSubviews: [art, labels, play, next]); stack.spacing = 10; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(stack)
        open.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(open)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12), stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12), stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            art.widthAnchor.constraint(equalToConstant: 46), art.heightAnchor.constraint(equalTo: art.widthAnchor), play.widthAnchor.constraint(equalToConstant: 40), next.widthAnchor.constraint(equalToConstant: 40),
            open.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), open.topAnchor.constraint(equalTo: contentView.topAnchor), open.bottomAnchor.constraint(equalTo: contentView.bottomAnchor), open.trailingAnchor.constraint(equalTo: play.leadingAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func refresh() {
        let player = MusicPlaybackController.shared
        titleLabel.text = player.nowPlaying?.title ?? "Not Playing"
        artistLabel.text = player.nowPlaying?.artist ?? "Choose a song from your library"
        art.image = MusicStyle.image(player.nowPlaying, size: 100) ?? UIImage(systemName: "music.note")
        art.contentMode = player.nowPlaying?.artwork == nil ? .center : .scaleAspectFill
        play.setImage(UIImage(systemName: player.isPlaying ? "pause.fill" : "play.fill"), for: .normal)
        play.accessibilityLabel = player.isPlaying ? "Pause" : "Play"
    }
}
