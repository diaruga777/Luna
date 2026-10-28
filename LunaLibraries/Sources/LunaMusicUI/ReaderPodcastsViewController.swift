import UIKit
import Combine
import LunaDesignSystem
import LunaModels
import LunaMusicCore
import LunaPodcastCore
import LunaStorage

/// Tap a text save to append its readout; Play Next is available in the long-press menu.
@MainActor public final class ReaderPodcastsViewController: MusicScreenViewController, UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating {
    public static var isReaderInstalled: Bool { UIApplication.shared.canOpenURL(URL(string: "luna://")!) }
    private let reader: ReaderPodcastController
    private let library: PodcastLibraryController
    private let initialSaveID: UUID?
    private var items: [SavedItem] = []
    private var visibleItems: [SavedItem] = []
    private let search = LibrarySearchController(placeholder: "Text Saves", identifier: "podcasts.reader.search", label: "Search Luna Reader")
    private var subscriptions = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var enqueueTasks: [UUID: Task<Void, Never>] = [:]
    private var hasLoaded = false

    public init(saveID: UUID? = nil, reader: ReaderPodcastController = .shared, library: PodcastLibraryController = .shared) {
        initialSaveID = saveID; self.reader = reader; self.library = library
        super.init(nibName: nil, bundle: nil)
        title = "Luna Reader"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad()
        table.dataSource = self; table.delegate = self
        table.register(UITableViewCell.self, forCellReuseIdentifier: "readerSave")
        table.accessibilityIdentifier = "podcasts.reader.saves"
        search.searchResultsUpdater = self; search.install(on: self)
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "list.bullet"), primaryAction: UIAction { [weak self] _ in
            (self?.navigationController as? MediaLibraryNavigationController)?.showPodcastQueue()
        })
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Podcast Queue"
        reader.objectWillChange.merge(with: library.objectWillChange).receive(on: DispatchQueue.main).sink { [weak self] in self?.reload() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: .savesChanged).receive(on: DispatchQueue.main).sink { [weak self] _ in self?.loadItems() }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification).sink { [weak self] _ in self?.loadItems() }.store(in: &subscriptions)
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.loadItems() }, for: .valueChanged)
        table.refreshControl = refresh
        if let initialSaveID { enqueue(initialSaveID) }
    }
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); loadItems()
    }
    private func loadItems() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            let items = await reader.items()
            guard !Task.isCancelled else { return }
            self.items = items; hasLoaded = true; table.refreshControl?.endRefreshing(); reload()
        }
    }
    public func reload() {
        guard isViewLoaded else { return }
        let query = search.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        visibleItems = items.filter { query.isEmpty || ($0.title ?? "").localizedStandardContains(query) || $0.urlString.localizedStandardContains(query) }
        if hasLoaded && visibleItems.isEmpty {
            var empty = UIContentUnavailableConfiguration.empty()
            empty.image = UIImage(systemName: "book")
            empty.text = query.isEmpty ? "No Text Saves" : "No Results"
            empty.secondaryText = query.isEmpty ? "Save an article or document in Luna Reader to listen here." : nil
            contentUnavailableConfiguration = empty
        } else { contentUnavailableConfiguration = nil }
        table.reloadData()
    }
    public func updateSearchResults(for searchController: UISearchController) { reload() }
    public func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { visibleItems.count }
    public func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = visibleItems[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "readerSave", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = item.cardTitle ?? item.url?.host ?? "Untitled"
        content.textProperties.numberOfLines = 2
        let id = ReaderPodcastSource.episodeID(item.id)
        let queued = library.state.queue.contains(id) || library.state.currentEpisodeID == id
        if let progress = reader.progress[item.id] {
            content.secondaryText = "Creating audio… \(Int(progress * 100))%"
            let spinner = UIActivityIndicatorView(style: .medium); spinner.startAnimating(); cell.accessoryView = spinner
        } else {
            content.secondaryText = queued ? "In Podcast Queue" : item.dateAdded.formatted(date: .abbreviated, time: .omitted)
            if queued { cell.accessoryView = nil }
            else {
                let add = UIButton(type: .system)
                add.setImage(UIImage(systemName: "plus.circle"), for: .normal)
                add.frame.size = CGSize(width: 44, height: 44)
                add.accessibilityLabel = "Add to Podcast Queue"
                if reader.hasGeminiAPIKey {
                    add.menu = queueMenu(item.id)
                    add.showsMenuAsPrimaryAction = true
                } else {
                    add.addAction(UIAction { [weak self] _ in self?.enqueue(item.id) }, for: .touchUpInside)
                }
                cell.accessoryView = add
            }
        }
        cell.accessoryType = queued ? .checkmark : .none
        cell.contentConfiguration = content
        cell.accessibilityIdentifier = "podcasts.reader.save.\(item.id.uuidString)"
        cell.accessibilityHint = "Add readout to podcast queue"
        return cell
    }
    public func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        enqueue(visibleItems[indexPath.row].id)
    }
    public func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let id = visibleItems[indexPath.row].id
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.queueMenu(id) ?? UIMenu(children: [])
        }
    }
    func queueMenu(_ id: UUID) -> UIMenu {
        var actions = [
            UIAction(title: "Add to Queue", image: UIImage(systemName: "text.line.last.and.arrowtriangle.forward")) { [weak self] _ in self?.enqueue(id) },
            UIAction(title: "Play Next", image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { [weak self] _ in self?.enqueue(id, next: true) },
        ]
        if reader.hasGeminiAPIKey {
            actions += [
                UIAction(title: L10n.string("Music_reader_addGemini"), image: UIImage(systemName: "waveform")) { [weak self] _ in self?.enqueue(id, voice: .gemini) },
                UIAction(title: L10n.string("Music_reader_nextGemini"), image: UIImage(systemName: "waveform")) { [weak self] _ in self?.enqueue(id, next: true, voice: .gemini) },
            ]
        }
        return UIMenu(children: actions)
    }
    private func enqueue(_ id: UUID, next: Bool = false, voice: ReaderPodcastController.Voice? = nil) {
        guard enqueueTasks[id] == nil else { return }
        guard Self.isReaderInstalled else {
            PodcastUI.showError(PodcastError("Install Luna Reader to add its text saves."), from: self); return
        }
        enqueueTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { enqueueTasks[id] = nil; reload() }
            do { try await reader.enqueue(id, next: next, voice: voice) }
            catch { PodcastUI.showError(error, from: self) }
        }
    }
}
