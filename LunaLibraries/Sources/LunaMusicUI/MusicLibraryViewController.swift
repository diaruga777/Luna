import UIKit
import MediaPlayer
import MusicKit
import LunaMusicCore

@MainActor
public final class MusicLibraryViewController: MusicScreenViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate {
    private let search = UISearchBar()
    private var pendingSearchFocus = false
    private let library = MusicLibraryController.shared
    private var results: [MusicResult] = []
    private var query: String { search.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    private var categories: [(String, String)] { [("Playlists", "music.note.list"), ("Artists", "mic.fill"), ("Albums", "square.stack"), ("Songs", "music.note"), ("Downloaded", "arrow.down.circle")] }
    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        navigationController?.navigationBar.prefersLargeTitles = true
        search.placeholder = "Your Library"
        search.searchTextField.accessibilityIdentifier = "music.library.search"
        search.searchBarStyle = .minimal
        search.delegate = self
        search.autocapitalizationType = .none
        search.autocorrectionType = .no
        search.accessibilityLabel = "Search songs, albums, artists, and playlists"
        search.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(search)
        tableTop.isActive = false
        NSLayoutConstraint.activate([search.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor), search.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8), search.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8), table.topAnchor.constraint(equalTo: search.bottomAnchor)])
        table.dataSource = self; table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        table.register(MusicArtworkGridCell.self, forCellReuseIdentifier: "grid")
        observe(.lunaMusicLibraryChanged) { [weak self] in self?.update() }
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), primaryAction: UIAction { [weak self] _ in Task { await self?.library.reload() } })
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Refresh Library"
        update()
        Task { await library.authorizeAndLoad(); update() }
    }
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if pendingSearchFocus { search.becomeFirstResponder(); pendingSearchFocus = false }
    }
    public func foregroundSearch(query: String = "") {
        pendingSearchFocus = true
        loadViewIfNeeded()
        if presentedViewController != nil { dismiss(animated: false) }
        navigationController?.popToRootViewController(animated: false)
        search.text = query
        update()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.view.window != nil else { return }
            self.search.becomeFirstResponder(); self.pendingSearchFocus = false
        }
    }
    public func showQueue() {
        pendingSearchFocus = false
        loadViewIfNeeded()
        if presentedViewController != nil { dismiss(animated: false) }
        presentPlayer(queue: true)
    }
    public func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { update() }
    public func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
    private func update() {
        results = []
        if !query.isEmpty {
            let found = library.search(query)
            results = found.songs.map(MusicResult.song) + found.albums.map(MusicResult.album)
                + found.artists.map(MusicResult.artist) + found.playlists.map(MusicResult.playlist)
        }
        table.reloadData()
        var configuration: UIContentUnavailableConfiguration?
        if library.authorizationStatus == .denied || library.authorizationStatus == .restricted {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: "music.note")
            empty.text = "Allow Music Access"
            empty.secondaryText = "Luna Music needs permission to show and play your music library. You can allow access in Settings."
            empty.button.title = "Open Settings"
            empty.buttonProperties.primaryAction = UIAction { _ in if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            configuration = empty
        } else if library.isLoading && library.songs.isEmpty {
            var empty = UIContentUnavailableConfiguration.loading(); empty.text = "Loading Your Library"; configuration = empty
        } else if !query.isEmpty && results.isEmpty {
            var empty = UIContentUnavailableConfiguration.search(); empty.secondaryText = "Try another song, artist, album, or playlist."; configuration = empty
        } else if library.songs.isEmpty && library.authorizationStatus == .authorized {
            var empty = UIContentUnavailableConfiguration.empty(); empty.image = UIImage(systemName: "music.note.list"); empty.text = "Your Library Is Empty"; empty.secondaryText = library.errorMessage ?? "Music you add to your iPhone’s music library will appear here."; configuration = empty
        }
        table.backgroundView = nil
        table.tableFooterView = nil
        if let configuration {
            let empty = UIContentUnavailableView(configuration: configuration)
            if query.isEmpty {
                empty.frame = CGRect(x: 0, y: 0, width: table.bounds.width, height: 240)
                table.tableFooterView = empty
            } else { table.backgroundView = empty }
        }
    }
    public func numberOfSections(in tableView: UITableView) -> Int { query.isEmpty ? 2 : 1 }
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if !query.isEmpty { return results.count }
        return section == 0 ? categories.count : Int(ceil(Double(recentAlbums.count) / 2))
    }
    private var recentAlbums: [MPMediaItemCollection] {
        Array(library.albums.sorted { ($0.representativeItem?.dateAdded ?? .distantPast) > ($1.representativeItem?.dateAdded ?? .distantPast) }.prefix(20))
    }
    public func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { query.isEmpty && section == 1 && !recentAlbums.isEmpty ? "Recently Added" : nil }
    public func tableView(_ tableView: UITableView, willDisplayHeaderView view: UIView, forSection section: Int) {
        guard let header = view as? UITableViewHeaderFooterView else { return }
        header.textLabel?.font = .preferredFont(forTextStyle: .title1)
        header.textLabel?.textColor = .label
        header.textLabel?.text = "Recently Added"
    }
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if query.isEmpty && indexPath.section == 1 {
            let cell = tableView.dequeueReusableCell(withIdentifier: "grid", for: indexPath) as! MusicArtworkGridCell
            let albums = recentAlbums
            let start = indexPath.row * 2
            cell.configure(Array(albums[start..<min(start + 2, albums.count)])) { [weak self] album in self?.open(.album(album)) }
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.accessoryView = nil
        if query.isEmpty {
            let category = categories[indexPath.row]
            var config = cell.defaultContentConfiguration(); config.text = category.0; config.image = UIImage(systemName: category.1)
            config.textProperties.font = .preferredFont(forTextStyle: .title2)
            config.imageProperties.tintColor = .label; config.imageProperties.reservedLayoutSize = CGSize(width: 34, height: 34)
            config.directionalLayoutMargins.top = 18; config.directionalLayoutMargins.bottom = 18
            cell.contentConfiguration = config; cell.accessoryType = .disclosureIndicator
        } else { results[indexPath.row].configure(cell, owner: self) }
        cell.backgroundColor = .clear
        return cell
    }
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if !query.isEmpty { open(results[indexPath.row]); return }
        guard indexPath.section == 0 else { return }
        let items: [MusicResult]
        switch indexPath.row {
        case 0: items = library.playlists.map(MusicResult.playlist)
        case 1: items = library.artists.map(MusicResult.artist)
        case 2: items = library.albums.map(MusicResult.album)
        case 3: items = library.songs.map(MusicResult.song)
        default: items = library.songs.filter { !$0.isCloudItem }.map(MusicResult.song)
        }
        view.endEditing(true)
        navigationController?.pushViewController(MusicCollectionViewController(title: categories[indexPath.row].0, results: items), animated: true)
    }
    private func open(_ result: MusicResult) {
        view.endEditing(true)
        result.open(from: self)
    }
}

internal enum MusicResult {
    case song(MPMediaItem), playlist(MPMediaPlaylist), album(MPMediaItemCollection), artist(MPMediaItemCollection)
    var name: String { switch self { case .song(let item): return item.title ?? "Unknown Song"; case .playlist(let item): return item.name ?? "Playlist"; case .album(let item): return item.representativeItem?.albumTitle ?? "Unknown Album"; case .artist(let item): return item.representativeItem?.artist ?? "Unknown Artist" } }
    var songs: [MPMediaItem] { switch self { case .song(let item): return [item]; case .playlist(let item): return item.items; case .album(let item), .artist(let item): return item.items } }
    var playlist: MPMediaPlaylist? { if case .playlist(let item) = self { return item }; return nil }
    @MainActor func configure(_ cell: UITableViewCell, owner: MusicScreenViewController) {
        cell.accessoryView = nil; cell.accessoryType = .disclosureIndicator
        if case .song(let item) = self { owner.configureSong(cell, item: item); cell.accessoryType = .none; return }
        var config = cell.defaultContentConfiguration(); config.text = name
        config.image = MusicStyle.image(songs.first, size: 120) ?? UIImage(systemName: "music.note.list")
        config.imageProperties.maximumSize = CGSize(width: 64, height: 64); config.imageProperties.cornerRadius = 8
        config.directionalLayoutMargins.top = 10; config.directionalLayoutMargins.bottom = 10
        if case .artist = self { config.imageProperties.cornerRadius = 32; config.secondaryText = "Artist" }
        if case .album = self { config.secondaryText = songs.first?.artist }
        if case .playlist = self { config.secondaryText = "Playlist · \(songs.count) songs" }
        config.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = config; cell.backgroundColor = .clear
    }
    @MainActor func open(from owner: MusicScreenViewController) {
        if case .song(let item) = self { MusicStyle.run(from: owner) { try await MusicPlaybackController.shared.playSong(item) }; return }
        if case .artist(let collection) = self {
            let grouped = Dictionary(grouping: collection.items, by: { $0.albumPersistentID })
            let albums = grouped.values.map { MusicResult.album(MPMediaItemCollection(items: $0)) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            owner.navigationController?.pushViewController(MusicCollectionViewController(title: name, results: albums, collection: self), animated: true)
        } else { owner.navigationController?.pushViewController(MusicCollectionViewController(title: name, results: songs.map(MusicResult.song), collection: self), animated: true) }
    }
}
