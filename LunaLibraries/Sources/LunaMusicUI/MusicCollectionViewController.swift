import UIKit
import MediaPlayer
import LunaMusicCore

@MainActor
internal final class MusicCollectionViewController: MusicScreenViewController, UITableViewDataSource, UITableViewDelegate {
    private var results: [MusicResult]
    private let collection: MusicResult?
    private var gridAlbums: [MPMediaItemCollection]? {
        let isArtist: Bool
        if case .artist = collection { isArtist = true } else { isArtist = false }
        guard isArtist || (title == "Albums" && collection == nil) else { return nil }
        return results.compactMap { if case .album(let album) = $0 { return album }; return nil }
    }
    init(title: String, results: [MusicResult], collection: MusicResult? = nil) {
        self.results = results; self.collection = collection
        super.init(nibName: nil, bundle: nil); self.title = title
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        table.dataSource = self; table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        table.register(MusicArtworkGridCell.self, forCellReuseIdentifier: "grid")
        let sort = UIMenu(title: "Sort By", children: [UIAction(title: "Title", image: UIImage(systemName: "textformat.abc")) { [weak self] _ in
            self?.results.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }; self?.table.reloadData()
        }, UIAction(title: "Recently Added", image: UIImage(systemName: "clock")) { [weak self] _ in
            self?.results.sort { ($0.songs.first?.dateAdded ?? .distantPast) > ($1.songs.first?.dateAdded ?? .distantPast) }; self?.table.reloadData()
        }])
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease"), menu: sort)
        if title == "Playlists" && collection == nil {
            let add = UIBarButtonItem(systemItem: .add, primaryAction: UIAction { [weak self] _ in self?.createPlaylist() })
            navigationItem.rightBarButtonItems = [navigationItem.rightBarButtonItem!, add]
            observe(.lunaMusicLibraryChanged) { [weak self] in self?.results = MusicLibraryController.shared.playlists.map(MusicResult.playlist); self?.table.reloadData() }
        }
        if let collection {
            navigationItem.largeTitleDisplayMode = .never
            let header = MusicCollectionHeader(result: collection)
            header.onPlay = { [weak self] shuffle in guard let self else { return }; MusicStyle.run(from: self) { try await MusicPlaybackController.shared.play(collection.songs, playlist: collection.playlist, shuffle: shuffle) } }
            table.tableHeaderView = header
        }
        if results.isEmpty {
            var config = UIContentUnavailableConfiguration.empty(); config.text = "No \(title ?? "Music")"; config.image = UIImage(systemName: "music.note")
            config.secondaryText = title == "Downloaded" ? "Music downloaded to this iPhone will appear here." : "Your music library updates here automatically."
            table.backgroundView = UIContentUnavailableView(configuration: config)
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = table.tableHeaderView else { return }
        let height = header.systemLayoutSizeFitting(CGSize(width: table.bounds.width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height
        if header.frame.width != table.bounds.width || abs(header.frame.height - height) > 1 { header.frame.size = CGSize(width: table.bounds.width, height: height); table.tableHeaderView = header }
    }
    private func createPlaylist() {
        let alert = UIAlertController(title: "New Playlist", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Playlist Name" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            MusicStyle.run(from: self) { _ = try await MusicLibraryController.shared.createPlaylist(name: name, items: []) }
        })
        present(alert, animated: true)
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { gridAlbums.map { ($0.count + 1) / 2 } ?? results.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if let albums = gridAlbums {
            let cell = tableView.dequeueReusableCell(withIdentifier: "grid", for: indexPath) as! MusicArtworkGridCell
            let start = indexPath.row * 2
            cell.configure(Array(albums[start..<min(start + 2, albums.count)])) { [weak self] album in guard let self else { return }; MusicResult.album(album).open(from: self) }
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath); results[indexPath.row].configure(cell, owner: self); return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true); guard gridAlbums == nil else { return }
        if case .song(let song) = results[indexPath.row], let playlist = collection?.playlist {
            MusicStyle.run(from: self) { try await MusicPlaybackController.shared.playSong(song, in: playlist) }
        } else { results[indexPath.row].open(from: self) }
    }
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard gridAlbums == nil, case .song(let item) = results[indexPath.row] else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in self?.songMenu(item) })
    }
}

@MainActor
private final class MusicCollectionHeader: UIView {
    var onPlay: ((Bool) -> Void)?
    init(result: MusicResult) {
        super.init(frame: .zero)
        let isArtist: Bool
        if case .artist = result { isArtist = true } else { isArtist = false }
        let artwork = MusicStyle.artwork(MusicStyle.image(result.songs.first, size: 600), corner: isArtist ? 100 : 14)
        let name = UILabel(); name.text = result.name; name.font = MusicStyle.font(isArtist ? 34 : 28, weight: .bold); name.adjustsFontForContentSizeCategory = true; name.numberOfLines = 0; name.textAlignment = .center
        var playConfiguration = UIButton.Configuration.filled()
        playConfiguration.baseBackgroundColor = isArtist ? .secondarySystemBackground : .white
        playConfiguration.baseForegroundColor = isArtist ? .label : .darkGray
        playConfiguration.title = "Play"
        playConfiguration.image = UIImage(systemName: "play.fill")
        playConfiguration.imagePadding = 8
        playConfiguration.cornerStyle = .capsule
        playConfiguration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = MusicStyle.font(22, weight: .semibold); return attributes
        }
        var shuffleConfiguration = playConfiguration
        shuffleConfiguration.baseBackgroundColor = .secondarySystemBackground
        shuffleConfiguration.baseForegroundColor = .label
        shuffleConfiguration.title = "Shuffle"
        shuffleConfiguration.image = UIImage(systemName: "shuffle")
        let play = UIButton(configuration: playConfiguration)
        let shuffle = UIButton(configuration: shuffleConfiguration)
        play.addAction(UIAction { [weak self] _ in self?.onPlay?(false) }, for: .touchUpInside)
        shuffle.addAction(UIAction { [weak self] _ in self?.onPlay?(true) }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: isArtist ? [play, shuffle] : [shuffle, play])
        buttons.spacing = 16
        buttons.distribution = isArtist ? .fillEqually : .fill
        if !isArtist {
            shuffle.configuration?.title = nil
            shuffle.accessibilityLabel = "Shuffle"
            shuffle.widthAnchor.constraint(equalToConstant: 60).isActive = true
        }
        let stack = UIStackView(arrangedSubviews: [artwork, name, buttons]); stack.axis = .vertical; stack.alignment = .center; stack.spacing = 22; stack.translatesAutoresizingMaskIntoConstraints = false; addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: topAnchor, constant: 16), stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -28), artwork.widthAnchor.constraint(equalTo: stack.widthAnchor, multiplier: isArtist ? 0.24 : 0.74), artwork.heightAnchor.constraint(equalTo: artwork.widthAnchor), name.widthAnchor.constraint(equalTo: stack.widthAnchor), buttons.widthAnchor.constraint(equalTo: stack.widthAnchor), buttons.heightAnchor.constraint(greaterThanOrEqualToConstant: 60)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
internal final class MusicArtworkGridCell: UITableViewCell {
    private let row = UIStackView()
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear; selectionStyle = .none; separatorInset = UIEdgeInsets(top: 0, left: 10000, bottom: 0, right: 0)
        row.spacing = 12; row.distribution = .fillEqually; row.alignment = .top; row.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(row)
        NSLayoutConstraint.activate([row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20), row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20), row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 10), row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -10)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ albums: [MPMediaItemCollection], select: @escaping (MPMediaItemCollection) -> Void) {
        row.arrangedSubviews.forEach { row.removeArrangedSubview($0); $0.removeFromSuperview() }
        for album in albums {
            let art = MusicStyle.artwork(MusicStyle.image(album.representativeItem))
            let label = UILabel(); label.text = album.representativeItem?.albumTitle ?? "Unknown Album"; label.font = MusicStyle.font(19); label.adjustsFontForContentSizeCategory = true
            let artist = UILabel(); artist.text = album.representativeItem?.artist; artist.font = MusicStyle.font(17); artist.textColor = .secondaryLabel; artist.adjustsFontForContentSizeCategory = true
            let stack = UIStackView(arrangedSubviews: [art, label, artist]); stack.axis = .vertical; stack.spacing = 4
            let tile = UIView(); stack.translatesAutoresizingMaskIntoConstraints = false; tile.addSubview(stack)
            let button = UIButton(type: .custom); button.translatesAutoresizingMaskIntoConstraints = false; tile.addSubview(button); button.accessibilityLabel = "\(label.text ?? "Album"), \(artist.text ?? "")"; button.addAction(UIAction { _ in select(album) }, for: .touchUpInside)
            NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: tile.leadingAnchor), stack.trailingAnchor.constraint(equalTo: tile.trailingAnchor), stack.topAnchor.constraint(equalTo: tile.topAnchor), stack.bottomAnchor.constraint(equalTo: tile.bottomAnchor), art.heightAnchor.constraint(equalTo: art.widthAnchor), button.leadingAnchor.constraint(equalTo: tile.leadingAnchor), button.trailingAnchor.constraint(equalTo: tile.trailingAnchor), button.topAnchor.constraint(equalTo: tile.topAnchor), button.bottomAnchor.constraint(equalTo: tile.bottomAnchor)])
            row.addArrangedSubview(tile)
        }
        if albums.count == 1 { row.addArrangedSubview(UIView()) }
    }
}
