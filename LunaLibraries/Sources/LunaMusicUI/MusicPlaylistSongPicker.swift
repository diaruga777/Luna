import UIKit
import MediaPlayer
import LunaMusicCore

/// A searchable, multi-select library sheet. Selection survives filtering; the
/// sheet stays open on an API error so the user can retry without losing work.
@MainActor
internal final class MusicPlaylistSongPicker: UITableViewController, UISearchResultsUpdating {
    private let playlist: MusicPlaylist
    private let search = UISearchController(searchResultsController: nil)
    private var selected = Set<MusicID>()
    private var isSaving = false
    var downloadedOnly: Bool {
        didSet { if isViewLoaded { updateFilterMenu(); updateSearchResults(for: search) } }
    }
    private let songProvider: () -> [MusicSong]
    private let addSongs: ([MusicSong]) async throws -> Void
    private var songs: [MusicSong] { songProvider().filter { $0.source == playlist.source } }
    private var filtered: [MusicSong] = []
    private func matchingSongs() -> [MusicSong] {
        let terms = (search.searchBar.text ?? "").split(whereSeparator: \.isWhitespace)
        return songs.filter { song in
            guard !downloadedOnly || !song.isCloudItem else { return false }
            let text = [song.title, song.artist, song.albumTitle].compactMap { $0 }.joined(separator: " ")
            return terms.allSatisfy { text.localizedStandardContains(String($0)) }
        }
    }
    init(playlist: MusicPlaylist, downloadedOnly: Bool = false,
         songProvider: (() -> [MusicSong])? = nil,
         addSongs: (([MusicSong]) async throws -> Void)? = nil) {
        self.playlist = playlist
        self.downloadedOnly = downloadedOnly
        self.songProvider = songProvider ?? { MusicLibraryController.shared.songs }
        self.addSongs = addSongs ?? { try await MusicLibraryController.shared.add($0, to: playlist) }
        super.init(style: .plain)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Add Music"
        view.tintColor = MusicStyle.tint
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "song")
        tableView.rowHeight = UITableView.automaticDimension
        search.obscuresBackgroundDuringPresentation = false
        search.searchResultsUpdater = self
        search.searchBar.placeholder = "Search Your Library"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Add", primaryAction: UIAction { [weak self] _ in self?.save() })
        updateFilterMenu()
        updateSelection()
        updateSearchResults(for: search)
    }
    private func updateFilterMenu() {
        let filter = UIBarButtonItem(image: UIImage(systemName: downloadedOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"), menu: MusicListFilter.menu(downloadedOnly: downloadedOnly) { [weak self] in self?.downloadedOnly.toggle() })
        filter.accessibilityLabel = "Music Filters"
        navigationItem.rightBarButtonItems = [navigationItem.rightBarButtonItem!, filter]
    }
    func updateSearchResults(for searchController: UISearchController) {
        filtered = matchingSongs()
        tableView.reloadData()
        if filtered.isEmpty {
            var empty = UIContentUnavailableConfiguration.search()
            empty.text = downloadedOnly ? "No Downloaded Music" : songs.isEmpty ? "Your Library Is Empty" : "No Results"
            empty.secondaryText = downloadedOnly ? "Download music or turn off the Downloaded filter." : songs.isEmpty ? "Add songs to your music library, then select them here." : "Try another song, album, or artist."
            tableView.backgroundView = UIContentUnavailableView(configuration: empty)
        } else { tableView.backgroundView = nil }
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { filtered.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let song = filtered[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "song", for: indexPath)
        var config = cell.defaultContentConfiguration()
        config.text = song.title ?? "Unknown Song"
        config.secondaryText = song.artist
        config.textProperties.numberOfLines = 1
        config.secondaryTextProperties.numberOfLines = 1
        config.image = MusicStyle.image(song, size: 100) ?? UIImage(systemName: "music.note")
        config.imageProperties.maximumSize = CGSize(width: 48, height: 48)
        config.imageProperties.cornerRadius = 5
        cell.contentConfiguration = config
        cell.accessoryType = selected.contains(song.persistentID) ? .checkmark : .none
        cell.accessibilityValue = selected.contains(song.persistentID) ? "Selected" : "Not selected"
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isSaving else { return }
        let id = filtered[indexPath.row].persistentID
        if !selected.insert(id).inserted { selected.remove(id) }
        tableView.reloadRows(at: [indexPath], with: .none)
        updateSelection()
    }
    private func updateSelection() {
        navigationItem.rightBarButtonItem?.title = selected.isEmpty ? "Add" : "Add (\(selected.count))"
        navigationItem.rightBarButtonItem?.isEnabled = !selected.isEmpty && !isSaving
        navigationItem.leftBarButtonItem?.isEnabled = !isSaving
        isModalInPresentation = isSaving
    }
    private func save() {
        guard !selected.isEmpty, !isSaving else { return }
        let items = songs.filter { selected.contains($0.persistentID) }
        isSaving = true
        updateSelection()
        Task {
            do {
                try await addSongs(items)
                dismiss(animated: true)
            } catch {
                isSaving = false
                updateSelection()
                let alert = UIAlertController(title: "Unable to Add Songs", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
            }
        }
    }
}
