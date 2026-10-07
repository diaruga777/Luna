import UIKit
import LunaPodcastCore
import LunaMusicCore

@MainActor public final class PodcastLibraryViewController: MusicScreenViewController {
    private let pages = UISegmentedControl(items: ["Home", "New", "Library", "Search"])
    private let content = PodcastBrowserViewController()
    public override func viewDidLoad() {
        super.viewDidLoad(); table.isHidden = true; mini.isHidden = true
        title = "Podcasts"; view.tintColor = .systemPurple
        navigationItem.titleView = pages; pages.selectedSegmentIndex = 0
        pages.accessibilityIdentifier = "podcasts.sections"
        pages.addAction(UIAction { [weak self] _ in guard let self else { return }; self.content.mode = self.pages.selectedSegmentIndex }, for: .valueChanged)
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
        Task { await PodcastLibraryController.shared.refresh(); await content.discover() }
    }
    public func showQueue() { loadViewIfNeeded(); content.presentPodcastPlayer(queue: true) }
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

@MainActor private final class PodcastBrowserViewController: PodcastListViewController, UISearchResultsUpdating {
    weak var navigationOwner: UIViewController? { didSet { configureSearch() } }
    var mode = 0 { didSet { configureSearch(); reload(); if mode == 1 { Task { await discover() } } } }
    private let search = UISearchController(searchResultsController: nil)
    private var searchTask: Task<Void, Never>?
    private var results: [PodcastDirectoryResult] = []
    private var charts: [PodcastDirectoryResult] = []
    private var message: String?
    private var searchToken = UUID()
    override func viewDidLoad() {
        super.viewDidLoad(); search.searchResultsUpdater = self; search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "All Podcasts"; search.searchBar.scopeButtonTitles = ["Shows", "Episodes", "Your Library"]
        search.searchBar.delegate = self; search.searchBar.accessibilityIdentifier = "podcasts.search"
        reload()
    }
    private func configureSearch() {
        navigationOwner?.navigationItem.searchController = mode == 3 ? search : nil
        navigationOwner?.navigationItem.hidesSearchBarWhenScrolling = false
    }
    func discover() async {
        guard charts.isEmpty else { return }
        do { charts = try await PodcastDirectory().charts(country: podcasts.state.settings.countryCode); message = nil }
        catch { message = error.localizedDescription }
        reload()
    }
    override func reload() {
        let state = podcasts.state
        let followed = state.shows.values.filter(\.followed).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let latest = PodcastPolicies.ordered(state.episodes.values.filter { state.shows[$0.showID]?.followed == true && state.progress[$0.id]?.listened != true }, newestFirst: true)
        table.tableFooterView = nil
        switch mode {
        case 0:
            sections = []
            if let id = state.lastPlayedEpisodeID, let episode = state.episodes[id] { sections.append(.init(title: "Continue Listening", rows: [.episode(episode)])) }
            let recent = state.progress.filter { $0.value.lastPlayedAt != nil }.sorted { $0.value.lastPlayedAt! > $1.value.lastPlayedAt! }.prefix(20).compactMap { state.episodes[$0.key] }
            sections += [.init(title: "Latest Episodes", rows: latest.prefix(30).map(Row.episode)), .init(title: "Recently Played", rows: recent.map(Row.episode))]
            if sections.allSatisfy({ $0.rows.isEmpty }) { empty("Your Podcasts", detail: "Find a show in New or Search, then follow it to see new episodes here.") }
        case 1:
            sections = [.init(title: "Top Shows", rows: charts.prefix(20).map(Row.directory)), .init(title: "Browse Categories", rows: PodcastDirectory.categories.map { category in
                .action(category.name, "square.grid.2x2") { [weak self] in self?.navigationController?.pushViewController(PodcastCategoryViewController(category: category), animated: true) }
            })]
            if let message { empty("Unable to Load Shows", detail: message) }
        case 2:
            sections = [.init(title: "Library", rows: [
                .action("Shows", "dot.radiowaves.left.and.right") { [weak self] in self?.openEpisodes(title: "Shows", shows: followed) },
                .action("Latest Episodes", "clock") { [weak self] in self?.openEpisodes(title: "Latest Episodes", episodes: latest) },
                .action("Saved", "bookmark") { [weak self] in self?.openEpisodes(title: "Saved", episodes: PodcastPolicies.ordered(state.episodes.values.filter { state.progress[$0.id]?.saved == true }, newestFirst: true)) },
                .action("Downloaded", "arrow.down.circle") { [weak self] in self?.openEpisodes(title: "Downloaded", episodes: PodcastPolicies.ordered(state.episodes.values.filter { PodcastDownloads.shared.localURL($0.id) != nil }, newestFirst: true)) },
                .action("Played", "checkmark.circle") { [weak self] in self?.openEpisodes(title: "Played", episodes: PodcastPolicies.ordered(state.episodes.values.filter { state.progress[$0.id]?.listened == true }, newestFirst: true)) }
            ]), .init(title: "Stations", rows: state.stations.map { station in .action(station.name, "rectangle.stack") { [weak self] in self?.navigationController?.pushViewController(PodcastStationViewController(id: station.id), animated: true) } }),
                .init(title: "Favorite Categories", rows: PodcastDirectory.categories.filter { state.settings.favoriteCategories.contains($0.id) }.map { category in .action(category.name, "star") { [weak self] in self?.navigationController?.pushViewController(PodcastCategoryViewController(category: category), animated: true) } })]
        default:
            let query = search.searchBar.text ?? ""
            if search.searchBar.selectedScopeButtonIndex == 2 {
                sections = [.init(title: "Your Library", rows: state.shows.values.filter { $0.title.localizedStandardContains(query) }.map(Row.show) + PodcastPolicies.ordered(state.episodes.values.filter { $0.title.localizedStandardContains(query) || PodcastUI.text($0.summary).localizedStandardContains(query) }, newestFirst: true).map(Row.episode))]
            } else { sections = [.init(title: search.searchBar.selectedScopeButtonIndex == 1 ? "Episodes" : "Shows", rows: results.map(Row.directory))] }
            if query.isEmpty { empty("Search Podcasts", detail: "Find shows and episodes by title, topic, or creator.") }
            else if sections.allSatisfy({ $0.rows.isEmpty }) { empty(message == nil ? "No Results" : "Search Unavailable", detail: message ?? "Try another title or topic.") }
        }
        super.reload()
    }
    func updateSearchResults(for searchController: UISearchController) {
        searchTask?.cancel(); let token = UUID(); searchToken = token
        let query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        results = []; message = nil; reload()
        guard !query.isEmpty, searchController.searchBar.selectedScopeButtonIndex != 2 else { return }
        let episodes = searchController.searchBar.selectedScopeButtonIndex == 1
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(300)); guard let self else { return }
                let results = try await PodcastDirectory().search(query, episodes: episodes, country: podcasts.state.settings.countryCode)
                guard !Task.isCancelled, searchToken == token else { return }
                self.results = results; reload()
            } catch { guard !Task.isCancelled, let self, searchToken == token else { return }; message = error.localizedDescription; reload() }
        }
    }
    private func openEpisodes(title: String, episodes: [PodcastEpisode] = [], shows: [PodcastShow] = []) {
        navigationController?.pushViewController(PodcastStaticListViewController(title: title, episodes: episodes, shows: shows), animated: true)
    }
}
extension PodcastBrowserViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, selectedScopeButtonIndexDidChange selectedScope: Int) { updateSearchResults(for: search) }
}
@MainActor final class PodcastStaticListViewController: PodcastListViewController {
    private let ids: [String]; private let showIDs: [String]
    init(title: String, episodes: [PodcastEpisode] = [], shows: [PodcastShow] = []) { ids = episodes.map(\.id); showIDs = shows.map(\.id); super.init(nibName: nil, bundle: nil); self.title = title }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() { super.viewDidLoad(); reload() }
    override func reload() {
        sections = [.init(title: "", rows: showIDs.compactMap { podcasts.state.shows[$0] }.map(Row.show) + ids.compactMap { podcasts.state.episodes[$0] }.map(Row.episode))]
        if sections[0].rows.isEmpty { empty("No Episodes", detail: "Episodes you add to this part of your library will appear here.") }
        super.reload()
    }
}
@MainActor private final class PodcastCategoryViewController: PodcastListViewController {
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
        Task { do { let rows = try await PodcastDirectory().charts(country: podcasts.state.settings.countryCode, genre: category.id); sections = [.init(title: "Top Shows", rows: rows.map(Row.directory))]; reload() } catch { empty("Unable to Load Shows", detail: error.localizedDescription) } }
    }
}
