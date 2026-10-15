import UIKit
import MediaPlayer
import MusicKit
import LunaMusicCore

@MainActor
public final class MusicLibraryViewController: MusicScreenViewController, UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, UISearchResultsUpdating {
    private let searchController = UISearchController(searchResultsController: nil)
    private var search: UISearchBar { searchController.searchBar }
    private var pendingSearchFocus = false
    private var searchTask: Task<Void, Never>?
    private var searchToken = UUID()
    private let library = MusicLibraryController.shared
    private var results: [MusicResult] = []
    private var showingSearchResults = false
    private var query: String { search.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    private lazy var podcasts = PodcastLibraryViewController()
    private var downloadedOnly = false
    private var categories: [(String, String)] { [("Playlists", "music.note.list"), ("Artists", "mic.fill"), ("Albums", "square.stack"), ("Songs", "music.note"), ("Podcasts", "dot.radiowaves.left.and.right")] }
    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "Library"
        navigationController?.navigationBar.prefersLargeTitles = true
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchResultsUpdater = self
        navigationItem.searchController = searchController
        navigationItem.preferredSearchBarPlacement = .stacked
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        search.placeholder = "Your Library"
        search.searchTextField.font = .preferredFont(forTextStyle: .body)
        search.searchTextField.accessibilityIdentifier = "music.library.search"
        search.delegate = self
        search.autocapitalizationType = .none
        search.autocorrectionType = .no
        search.accessibilityLabel = "Search songs, albums, artists, and playlists"
        table.dataSource = self; table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        observe(.lunaMusicLibraryChanged) { [weak self] in self?.update() }
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "arrow.clockwise"), primaryAction: UIAction { [weak self] _ in Task { await self?.library.reload() } })
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Refresh Library"
        let settings = UIBarButtonItem(image: UIImage(systemName: "gearshape"), primaryAction: UIAction { [weak self] _ in
            self?.navigationController?.pushViewController(MusicSettingsViewController(), animated: true)
        })
        settings.accessibilityLabel = "Settings"
        navigationItem.rightBarButtonItems = [settings, navigationItem.rightBarButtonItem!]
        updateFilterMenu()
        update()
        Task { await library.authorizeAndLoad(); update() }
    }
    public override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if pendingSearchFocus { searchController.isActive = true; search.becomeFirstResponder(); pendingSearchFocus = false }
    }
    public func foregroundSearch(query: String = "") {
        pendingSearchFocus = true
        loadViewIfNeeded()
        if presentedViewController != nil { dismiss(animated: false) }
        navigationController?.popToRootViewController(animated: false)
        // UIKit can keep the integrated search controller active across a trip
        // to SpringBoard while dropping its first responder. Restart its native
        // presentation before asking for the keyboard again.
        searchController.isActive = false
        search.text = query
        update()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.view.window != nil else { return }
            self.searchController.isActive = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                guard let self, self.view.window != nil else { return }
                self.search.becomeFirstResponder()
                self.pendingSearchFocus = false
            }
        }
    }
    @discardableResult
    public func showPodcasts(animated: Bool = true) -> PodcastLibraryViewController {
        pendingSearchFocus = false
        loadViewIfNeeded()
        searchController.isActive = false
        view.endEditing(true)
        if presentedViewController != nil { dismiss(animated: false) }
        guard let navigationController else { return podcasts }
        if navigationController.viewControllers.contains(where: { $0 === podcasts }) {
            navigationController.popToViewController(podcasts, animated: false)
        } else {
            navigationController.popToRootViewController(animated: false)
            navigationController.pushViewController(podcasts, animated: animated)
        }
        return podcasts
    }
    private func updateFilterMenu() {
        let filter = UIBarButtonItem(image: UIImage(systemName: downloadedOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"), menu: MusicListFilter.menu(downloadedOnly: downloadedOnly) { [weak self] in
            guard let self else { return }
            self.downloadedOnly.toggle()
            self.updateFilterMenu()
            self.update()
        })
        filter.accessibilityLabel = "Music Filters"
        navigationItem.rightBarButtonItems = (navigationItem.rightBarButtonItems ?? []).filter { $0.accessibilityLabel != "Music Filters" } + [filter]
    }
    public func showQueue() {
        pendingSearchFocus = false
        loadViewIfNeeded()
        if presentedViewController != nil { dismiss(animated: false) }
        searchController.isActive = false
        navigationController?.popToRootViewController(animated: false)
        presentPlayer(queue: true)
    }
    public func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) { update() }
    public func updateSearchResults(for searchController: UISearchController) { update() }
    public func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
    private func update() {
        searchTask?.cancel()
        let token = UUID(); searchToken = token
        let text = query
        guard !text.isEmpty else { results = []; renderResults(); return }
        searchTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard let self else { return }
            let found = await library.searchInBackground(text)
            guard !Task.isCancelled, searchToken == token, query == text else { return }
            results = found.songs.map(MusicResult.song) + found.albums.map(MusicResult.album)
                + found.artists.map(MusicResult.artist) + found.playlists.map(MusicResult.playlist)
            if downloadedOnly { results = results.filter { $0.hasDownloadedSongs } }
            renderResults()
        }
    }
    private func renderResults() {
        showingSearchResults = !query.isEmpty
        table.reloadData()
        var configuration: UIContentUnavailableConfiguration?
        if library.songs.isEmpty && (library.authorizationStatus == .denied || library.authorizationStatus == .restricted) {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: "music.note")
            empty.text = "Allow Music Access"
            empty.secondaryText = "Allow access for Apple Music, or connect Luna Mac in Luna Music Settings to play your Vault files."
            empty.button.title = "Open Settings"
            empty.buttonProperties.primaryAction = UIAction { _ in if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
            configuration = empty
        } else if library.isLoading && library.songs.isEmpty {
            var empty = UIContentUnavailableConfiguration.loading(); empty.text = "Loading Your Library"; configuration = empty
        } else if !query.isEmpty && results.isEmpty {
            var empty = UIContentUnavailableConfiguration.search(); empty.secondaryText = downloadedOnly ? "Try another search or turn off the Downloaded filter." : "Try another song, artist, album, or playlist."; configuration = empty
        } else if library.songs.isEmpty && library.authorizationStatus == .authorized {
            var empty = UIContentUnavailableConfiguration.empty(); empty.image = UIImage(systemName: "music.note.list"); empty.text = "Your Library Is Empty"; empty.secondaryText = library.errorMessage ?? "Add music to your Apple library or connect Luna Mac in Settings to discover Vault songs."; configuration = empty
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
    public func numberOfSections(in tableView: UITableView) -> Int { 1 }
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        showingSearchResults ? results.count : categories.count
    }
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.accessoryView = nil
        if !showingSearchResults {
            let category = categories[indexPath.row]
            var config = cell.defaultContentConfiguration(); config.text = category.0; config.image = UIImage(systemName: category.1)
            config.textProperties.font = .preferredFont(forTextStyle: .title2)
            config.imageProperties.tintColor = .label; config.imageProperties.reservedLayoutSize = CGSize(width: 34, height: 34)
            config.directionalLayoutMargins.top = 12; config.directionalLayoutMargins.bottom = 12
            cell.contentConfiguration = config; cell.accessoryType = .disclosureIndicator
        } else { results[indexPath.row].configure(cell, owner: self, downloadedOnly: downloadedOnly) }
        cell.backgroundColor = .clear
        return cell
    }
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if showingSearchResults {
            guard results.indices.contains(indexPath.row) else { return }
            open(results[indexPath.row]); return
        }
        guard indexPath.section == 0 else { return }
        if indexPath.row == 4 { showPodcasts(); return }
        let items: [MusicResult]
        switch indexPath.row {
        case 0: items = library.playlists.map(MusicResult.playlist)
        case 1: items = library.artists.map(MusicResult.artist)
        case 2: items = library.albums.map(MusicResult.album)
        case 3: items = library.songs.map(MusicResult.song)
        default: return
        }
        view.endEditing(true)
        navigationController?.pushViewController(MusicCollectionViewController(title: categories[indexPath.row].0, results: items, downloadedOnly: downloadedOnly), animated: true)
    }
    private func open(_ result: MusicResult) {
        view.endEditing(true)
        result.open(from: self, downloadedOnly: downloadedOnly)
    }
}

internal enum MusicResult: Sendable {
    case song(MusicSong), playlist(MusicPlaylist), album(MusicCollection), artist(MusicCollection)
    var name: String { switch self { case .song(let item): return item.title ?? "Unknown Song"; case .playlist(let item): return item.name ?? "Playlist"; case .album(let item): return item.representativeItem?.albumTitle ?? "Unknown Album"; case .artist(let item): return item.representativeItem?.artist ?? "Unknown Artist" } }
    var songs: [MusicSong] { switch self { case .song(let item): return [item]; case .playlist(let item): return item.items; case .album(let item), .artist(let item): return item.items } }
    @MainActor var hasDownloadedSongs: Bool { songs.contains { !$0.isCloudItem } }
    var playlist: MusicPlaylist? { if case .playlist(let item) = self { return item }; return nil }
    @MainActor func artwork(size: CGFloat = 600) -> UIImage? {
        guard case .playlist = self else { return MusicStyle.image(songs.first, size: size) }
        var seen = Set<MusicID>()
        var covers: [UIImage] = []
        for song in songs {
            guard seen.insert(song.albumPersistentID).inserted,
                  let cover = MusicStyle.image(song, size: size / 2) else { continue }
            covers.append(cover)
            if covers.count == 4 { break }
        }
        guard covers.count == 4 else { return MusicStyle.image(songs.first, size: size) }
        return UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            for (index, cover) in covers.enumerated() {
                cover.draw(in: CGRect(x: CGFloat(index % 2) * size / 2, y: CGFloat(index / 2) * size / 2, width: size / 2, height: size / 2))
            }
        }
    }
    @MainActor func configure(_ cell: UITableViewCell, owner: MusicScreenViewController, downloadedOnly: Bool = false) {
        cell.accessoryView = nil; cell.accessoryType = .disclosureIndicator
        if case .song(let item) = self { owner.configureSong(cell, item: item, downloadedOnly: downloadedOnly); cell.accessoryType = .none; return }
        var config = cell.defaultContentConfiguration(); config.text = name
        config.image = artwork(size: 120) ?? UIImage(systemName: "music.note.list")
        config.imageProperties.maximumSize = CGSize(width: 64, height: 64); config.imageProperties.cornerRadius = 6
        config.textProperties.font = MusicStyle.font(20)
        config.secondaryTextProperties.font = MusicStyle.font(17)
        config.directionalLayoutMargins.leading = 20; config.directionalLayoutMargins.trailing = 20
        config.imageToTextPadding = 12
        config.directionalLayoutMargins.top = 8; config.directionalLayoutMargins.bottom = 8
        if case .playlist(let playlist) = self { config.secondaryText = playlist.source == .vault ? "Luna Vault" : "Apple Music" }
        if case .artist = self { config.imageProperties.cornerRadius = 32; config.secondaryText = "Artist" }
        if case .album = self { config.secondaryText = songs.first?.artist }

        config.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = config; cell.backgroundColor = .clear
    }
    @MainActor func open(from owner: MusicScreenViewController, downloadedOnly: Bool = false) {
        if case .song(let item) = self { MusicStyle.run(from: owner) { try await MusicPlaybackController.shared.playSong(item, downloadedOnly: downloadedOnly) }; return }
        if case .artist(let collection) = self {
            let grouped = Dictionary(grouping: collection.items, by: { $0.albumPersistentID })
            let albums = grouped.values.map { MusicResult.album(MusicCollection(items: $0)) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            owner.navigationController?.pushViewController(MusicCollectionViewController(title: name, results: albums, collection: self, downloadedOnly: downloadedOnly), animated: true)
        } else { owner.navigationController?.pushViewController(MusicCollectionViewController(title: name, results: songs.map(MusicResult.song), collection: self, downloadedOnly: downloadedOnly), animated: true) }
    }
}
