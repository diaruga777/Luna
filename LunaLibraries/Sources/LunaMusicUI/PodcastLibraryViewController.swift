import UIKit
import Combine
import LunaPodcastCore
import LunaMusicCore
import LunaDesignSystem

@MainActor public final class PodcastLibraryViewController: UIViewController {
    private let content = PodcastBrowserViewController()
    private var foregroundObserver: NSObjectProtocol?
    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated); content.reload()
    }
    deinit { if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) } }
    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "Podcasts"; view.tintColor = .systemPurple
        foregroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.content.reload() }
        }
        navigationController?.navigationBar.prefersLargeTitles = true
        content.mode = 4
        addChild(content); view.addSubview(content.view); content.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), content.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), content.view.topAnchor.constraint(equalTo: view.topAnchor), content.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        content.didMove(toParent: self)
        content.navigationOwner = self
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [
            UIAction(title: "Follow a Show by URL", image: UIImage(systemName: "link")) { [weak self] _ in self?.addURL() },
            UIAction(title: "New Station", image: UIImage(systemName: "rectangle.stack.badge.plus")) { [weak self] _ in self?.newStation() },
            UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in self?.navigationController?.pushViewController(PodcastSettingsViewController(), animated: true) }
        ]))
        navigationItem.rightBarButtonItem?.accessibilityLabel = "Podcast Options"
        Task { await PodcastLibraryController.shared.refresh() }
    }
    public func showQueue() { loadViewIfNeeded(); content.presentPodcastPlayer(queue: true) }
    public func foregroundSearch(query: String = "") {
        loadViewIfNeeded()
        content.foregroundSearch(query: query)
    }
    func applySharedSearchQuery(_ query: String) {
        loadViewIfNeeded()
        content.applySharedSearchQuery(query)
    }
    public func openEpisode(_ id: String) {
        guard let episode = PodcastLibraryController.shared.state.episodes[id] else { return }
        navigationController?.pushViewController(PodcastEpisodeViewController(episode: episode), animated: true)
    }
    private func addURL() {
        let alert = UIAlertController(title: "Follow a Show by URL", message: "Enter the podcast’s RSS feed address.", preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "https://example.com/feed.xml"; $0.keyboardType = .URL; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Follow", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let address = alert?.textFields?.first?.text
            PodcastUI.run(self) {
                guard let url = PodcastIdentity.webURL(address) else { throw PodcastError("Enter a valid podcast feed address.") }
                let id = try await PodcastLibraryController.shared.addFeed(url)
                guard self.navigationController?.topViewController === self else { return }
                self.navigationController?.pushViewController(PodcastShowViewController(showID: id), animated: true)
            }
        }); present(alert, animated: true)
    }
    private func newStation() {
        let alert = UIAlertController(title: "New Station", message: nil, preferredStyle: .alert); alert.addTextField { $0.placeholder = "Station Name" }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            guard let self, let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return }
            PodcastUI.run(self) {
                let station = PodcastStation(name: name)
                try PodcastLibraryController.shared.edit { $0.stations.append(station) }
                self.navigationController?.pushViewController(PodcastStationSettingsViewController(id: station.id), animated: true)
            }
        }); present(alert, animated: true)
    }
}

@MainActor final class PodcastBrowserViewController: PodcastListViewController, UISearchResultsUpdating {
    weak var navigationOwner: UIViewController? { didSet { configureSearch() } }
    var mode = 0 { didSet { cancelDirectoryOpening(); cancelPrefetching(); configureSearch(); reload(); if mode == 1 { Task { await discover() } } } }
    var youtube = YouTubePodcastController.shared
    private var youtubeAvailability: AnyCancellable?
    private let search = LibrarySearchController(placeholder: "All Podcasts", identifier: "podcasts.search", label: "Search podcasts")
    private var searchTask: Task<Void, Never>?
    private var results: [PodcastDirectoryResult] = []
    private var discoveryMessage: String?
    private var categoryPrefetchTask: Task<Void, Never>?
    private var isDiscovering = false
    private var charts: [PodcastDirectoryResult] = []
    private var message: String?
    private var searchToken = UUID()
    private(set) var isSearching = false
    var directory = PodcastDirectory()
    override func viewDidLoad() {
        super.viewDidLoad(); search.searchResultsUpdater = self
        search.searchBar.placeholder = "All Podcasts"; search.searchBar.scopeButtonTitles = ["Shows", "Episodes", "Your Library"]
        search.searchBar.delegate = self; search.searchBar.accessibilityIdentifier = "podcasts.search"
        youtubeAvailability = youtube.$available.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        configureSearch(); reload()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        youtube.restoreAvailability(); reload()
        Task { await youtube.refreshAvailability() }
    }
    private func configureSearch() {
        if mode == 3 || mode == 4 { search.install(on: navigationOwner ?? self) }
    }
    func foregroundSearch(query: String) {
        loadViewIfNeeded()
        configureSearch()
        search.searchBar.text = query
        updateSearchResults(for: search)
        NotificationCenter.default.post(name: .lunaMusicSearchQueryChanged, object: nil,
                                        userInfo: ["query": query, "source": "podcasts"])
        DispatchQueue.main.async { [weak self] in
            guard let self, self.view.window != nil else { return }
            self.search.focusSearch()
        }
    }
    func applySharedSearchQuery(_ query: String) {
        guard search.searchBar.text != query else { return }
        search.searchBar.text = query
        updateSearchResults(for: search)
    }
    private var showingSearch: Bool {
        mode == 3 || (mode == 4 && !(search.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private func openPage(_ mode: Int, title: String) {
        view.endEditing(true)
        let page = PodcastBrowserViewController(); page.youtube = youtube; page.mode = mode; page.title = title
        navigationController?.pushViewController(page, animated: true)
    }
    func discover(force: Bool = false) async {
        guard charts.isEmpty, !isDiscovering else { return }
        isDiscovering = true; reload()
        defer { isDiscovering = false; reload() }
        do {
            charts = try await directory.charts(country: podcasts.state.settings.countryCode, force: force)
            discoveryMessage = nil; prefetch(Array(charts.prefix(3)))
            if categoryPrefetchTask == nil {
                let country = podcasts.state.settings.countryCode
                let categories = Array((podcasts.state.settings.favoriteCategories + PodcastDirectory.categories.map(\.id)).prefix(3))
                categoryPrefetchTask = Task { for id in Set(categories) { _ = try? await directory.charts(country: country, genre: id) } }
            }
        } catch { discoveryMessage = error.localizedDescription }
    }
    override func refreshContent() async {
        async let availability: Void = youtube.refreshAvailability()
        if mode == 1 { charts = []; await discover(force: true) }
        else if showingSearch { updateSearchResults(for: search); await searchTask?.value }
        else { await super.refreshContent() }
        await availability
    }
    override func reload() {
        let state = podcasts.state
        let followed = state.shows.values.filter(\.followed).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let latest = PodcastPolicies.ordered(state.episodes.values.filter { state.shows[$0.showID]?.followed == true && state.progress[$0.id]?.listened != true }, newestFirst: true)
        table.tableFooterView = nil; table.tableHeaderView = nil
        switch showingSearch ? 3 : mode {
        case 0:
            sections = youtube.available ? [.init(title: "", rows: youtubeRows)] : []
            if let id = state.lastPlayedEpisodeID, let episode = state.episodes[id] { sections.append(.init(title: "Continue Listening", rows: [.episode(episode)])) }
            let recent = state.progress.filter { $0.value.lastPlayedAt != nil }.sorted { $0.value.lastPlayedAt! > $1.value.lastPlayedAt! }.prefix(20).compactMap { state.episodes[$0.key] }
            sections += [.init(title: "Latest Episodes", rows: latest.prefix(30).map(Row.episode)), .init(title: "Recently Played", rows: recent.map(Row.episode))]
            if podcasts.isRefreshing { loading("Updating Podcasts") }
            else if sections.allSatisfy({ $0.rows.isEmpty }) { empty("Your Podcasts", detail: "Follow a show to get new episodes.") }
        case 1:
            sections = [.init(title: "Top Shows", rows: charts.prefix(20).map(Row.directory)), .init(title: "Browse Categories", rows: PodcastDirectory.categories.map { category in
                .action(category.name, "square.grid.2x2") { [weak self] in self?.navigationController?.pushViewController(PodcastCategoryViewController(category: category), animated: true) }
            })]
            if isDiscovering { loading("Loading Top Shows", atTop: true) }
            else if let message = discoveryMessage { empty("Unable to Load Shows", detail: message, atTop: true, retry: { [weak self] in Task { await self?.discover() } }) }
        case 2, 4:
            let browsing: [Row] = mode == 4 ? [
                .action("Home", "house") { [weak self] in self?.openPage(0, title: "Home") }
            ] + youtubeRows + [
                .action("New", "sparkles") { [weak self] in self?.openPage(1, title: "New") }
            ] : []
            sections = [.init(title: "", rows: browsing + (ReaderPodcastsViewController.isReaderInstalled ? [
                .action("Luna Reader", "book") { [weak self] in self?.navigationController?.pushViewController(ReaderPodcastsViewController(), animated: true) }
            ] : []) + [
                .action("Shows", "dot.radiowaves.left.and.right") { [weak self] in self?.openEpisodes(title: "Shows", shows: followed) },
                .action("Latest Episodes", "clock") { [weak self] in self?.openEpisodes(title: "Latest Episodes", episodes: latest) },
                .action("Downloaded", "arrow.down.circle") { [weak self] in self?.openEpisodes(title: "Downloaded", episodes: PodcastPolicies.ordered(state.episodes.values.filter { PodcastDownloads.shared.localURL($0.id) != nil }, newestFirst: true)) },
                .action("Played", "checkmark.circle") { [weak self] in self?.openEpisodes(title: "Played", episodes: PodcastPolicies.ordered(state.episodes.values.filter { state.progress[$0.id]?.listened == true }, newestFirst: true)) }
            ]), .init(title: "Stations", rows: state.stations.map { station in .action(station.name, "rectangle.stack") { [weak self] in self?.navigationController?.pushViewController(PodcastStationViewController(id: station.id), animated: true) } }),
                .init(title: "Favorite Categories", rows: PodcastDirectory.categories.filter { state.settings.favoriteCategories.contains($0.id) }.map { category in .action(category.name, "star") { [weak self] in self?.navigationController?.pushViewController(PodcastCategoryViewController(category: category), animated: true) } })]
            sections.removeAll { $0.rows.isEmpty }
        default:
            let query = search.searchBar.text ?? ""
            if search.searchBar.selectedScopeButtonIndex == 2 {
                sections = [.init(title: "Your Library", rows: state.shows.values.filter { $0.title.localizedStandardContains(query) }.map(Row.show) + PodcastPolicies.ordered(state.episodes.values.filter { $0.title.localizedStandardContains(query) || PodcastUI.text($0.summary).localizedStandardContains(query) }, newestFirst: true).map(Row.episode))]
            } else { sections = [.init(title: search.searchBar.selectedScopeButtonIndex == 1 ? "Episodes" : "Shows", rows: results.map(Row.directory))] }
            if query.isEmpty { empty("Search Podcasts", detail: "Try a show name, topic, or creator.") }
            else if isSearching { loading("Searching Podcasts") }
            else if sections.allSatisfy({ $0.rows.isEmpty }) { empty(message == nil ? "No Results" : "Search Unavailable", detail: message ?? "Try another title or topic.", retry: message == nil ? nil : { [weak self] in guard let self else { return }; self.updateSearchResults(for: self.search) }) }
        }
        super.reload()
    }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = super.tableView(tableView, cellForRowAt: indexPath)
        if mode == 4 && !showingSearch, var config = cell.contentConfiguration as? UIListContentConfiguration {
            if case .action(let title, _, _) = sections[indexPath.section].rows[indexPath.row], title == "Luna Reader" {
                config.image = LunaAppIconImage.image(for: .reader)?.withRenderingMode(.alwaysOriginal)
                config.imageProperties.maximumSize = CGSize(width: 30, height: 30)
                config.imageProperties.cornerRadius = 7
            }
            config.textProperties.font = .preferredFont(forTextStyle: .title2)
            config.imageProperties.tintColor = .label
            config.imageProperties.reservedLayoutSize = CGSize(width: 34, height: 34)
            config.directionalLayoutMargins.top = 12; config.directionalLayoutMargins.bottom = 12
            cell.contentConfiguration = config
        }
        return cell
    }
    func updateSearchResults(for searchController: UISearchController) {
        cancelDirectoryOpening(); cancelPrefetching()
        searchTask?.cancel(); let token = UUID(); searchToken = token
        let query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        isSearching = !query.isEmpty && searchController.searchBar.selectedScopeButtonIndex != 2
        results = []; message = nil; reload()
        guard isSearching else { return }
        let episodes = searchController.searchBar.selectedScopeButtonIndex == 1
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300)); guard let self else { return }
                let results = try await directory.search(query, episodes: episodes, country: podcasts.state.settings.countryCode)
                guard !Task.isCancelled, searchToken == token else { return }
                self.results = results; isSearching = false; reload(); prefetch(Array(results.prefix(3)))
            } catch { guard !Task.isCancelled, let self, searchToken == token else { return }; message = error.localizedDescription; isSearching = false; reload() }
        }
    }
    private var youtubeRows: [Row] {
        guard youtube.available else { return [] }
        return [.action("Add YouTube Audio", "link") { [weak self] in self?.addYouTubeAudio() }]
    }
    private func addYouTubeAudio() {
        let alert = UIAlertController(title: "Add YouTube Audio", message: nil, preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "YouTube link"; $0.keyboardType = .URL
            $0.autocapitalizationType = .none; $0.autocorrectionType = .no
            $0.accessibilityIdentifier = "podcasts.youtubeURL"
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add to Queue", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let input = alert?.textFields?.first?.text ?? ""
            PodcastUI.run(self) { _ = try await self.youtube.enqueue(input) }
        })
        present(alert, animated: true)
    }
    private func openEpisodes(title: String, episodes: [PodcastEpisode] = [], shows: [PodcastShow] = []) {
        navigationController?.pushViewController(PodcastStaticListViewController(title: title, episodes: episodes, shows: shows), animated: true)
    }
}
extension PodcastBrowserViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        NotificationCenter.default.post(name: .lunaMusicSearchQueryChanged, object: nil,
                                        userInfo: ["query": searchText, "source": "podcasts"])
    }
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) { searchBar.resignFirstResponder() }
    func searchBar(_ searchBar: UISearchBar, selectedScopeButtonIndexDidChange selectedScope: Int) { updateSearchResults(for: search) }
}
@MainActor final class PodcastStaticListViewController: PodcastListViewController {
    private let ids: [String]; private let showIDs: [String]
    init(title: String, episodes: [PodcastEpisode] = [], shows: [PodcastShow] = []) { ids = episodes.map(\.id); showIDs = shows.map(\.id); super.init(nibName: nil, bundle: nil); self.title = title }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() { super.viewDidLoad(); reload() }
    override func reload() {
        sections = [.init(title: "", rows: showIDs.compactMap { podcasts.state.shows[$0] }.map(Row.show) + ids.compactMap { podcasts.state.episodes[$0] }.map(Row.episode))]
        if sections[0].rows.isEmpty { empty("No Episodes", detail: "No episodes yet.") }
        super.reload()
    }
}
@MainActor final class PodcastCategoryViewController: PodcastListViewController {
    var directory = PodcastDirectory()
    private(set) var isLoading = false
    let category: (id: String, name: String)
    init(category: (id: String, name: String)) { self.category = category; super.init(nibName: nil, bundle: nil); title = category.name }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "star"), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }; PodcastUI.run(self) {
                try self.podcasts.edit { state in
                    if state.settings.favoriteCategories.contains(self.category.id) { state.settings.favoriteCategories.removeAll { $0 == self.category.id } }
                    else { state.settings.favoriteCategories.append(self.category.id) }
                }
                self.navigationItem.rightBarButtonItem?.image = UIImage(systemName: self.podcasts.state.settings.favoriteCategories.contains(self.category.id) ? "star.fill" : "star")
            }
        })
        loading("Loading Shows"); Task { await load(force: false) }
    }
    override func refreshContent() async { await load(force: true) }
    private func load(force: Bool) async {
        guard !isLoading else { return }
        isLoading = true; loading("Loading Shows")
        defer { isLoading = false }
        do {
            let rows = try await directory.charts(country: podcasts.state.settings.countryCode, genre: category.id, force: force)
            sections = [.init(title: "Top Shows", rows: rows.map(Row.directory))]
            table.tableFooterView = nil; reload(); prefetch(Array(rows.prefix(3)))
        } catch { empty("Unable to Load Shows", detail: error.localizedDescription, retry: { [weak self] in Task { await self?.refreshContent() } }) }
    }
}
