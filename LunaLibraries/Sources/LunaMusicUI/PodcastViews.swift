import UIKit
import Combine
import LunaPodcastCore
import LunaMusicCore
import LunaDesignSystem

@MainActor enum PodcastUI {
    static let images: NSCache<NSURL, UIImage> = { let cache = NSCache<NSURL, UIImage>(); cache.totalCostLimit = 32 * 1_024 * 1_024; return cache }()
    private static var imageTasks: [URL: Task<UIImage?, Never>] = [:]
    static func image(_ url: URL) async -> UIImage? {
        if let image = images.object(forKey: url as NSURL) { return image }
        if let task = imageTasks[url] { return await task.value }
        let task = Task<UIImage?, Never> {
            var request = URLRequest(url: url); request.timeoutInterval = 20
            guard let (data, response) = try? await PodcastNetwork.session.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count < 15_000_000 else { return nil }
            return await UIImage(data: data)?.byPreparingThumbnail(ofSize: CGSize(width: 600, height: 600))
        }
        imageTasks[url] = task
        let image = await task.value; imageTasks[url] = nil
        if let image { images.setObject(image, forKey: url as NSURL, cost: Int(image.size.width * image.size.height * 4)) }
        return image
    }
    static func text(_ html: String) -> String {
        html.replacingOccurrences(of: "</p>|<br\\s*/?>|</div>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&nbsp;", with: " ")
    }
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let value = max(0, Int(seconds)); return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
    }
    static func artwork(_ url: URL?, into view: UIImageView) {
        view.image = UIImage(systemName: "dot.radiowaves.left.and.right"); view.contentMode = .scaleAspectFit
        view.accessibilityIdentifier = url?.absoluteString
        guard let url else { return }
        if let image = images.object(forKey: url as NSURL) { view.image = image; view.contentMode = .scaleAspectFill; return }
        Task { @MainActor [weak view] in
            guard let image = await image(url) else { return }
            guard view?.accessibilityIdentifier == url.absoluteString else { return }
            view?.image = image; view?.contentMode = .scaleAspectFill
        }
    }
    static func showError(_ error: Error, from controller: UIViewController) {
        guard !(error is CancellationError), controller.presentedViewController == nil else { return }
        let alert = UIAlertController(title: "Podcasts", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default)); controller.present(alert, animated: true)
    }
    static func run(_ controller: UIViewController, action: @escaping () async throws -> Void) {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.isAccessibilityElement = true; spinner.accessibilityLabel = "Loading"; spinner.accessibilityIdentifier = "podcasts.actionLoading"
        spinner.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(spinner)
        NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor), spinner.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor, constant: 8)])
        spinner.startAnimating()
        Task {
            defer { spinner.removeFromSuperview() }
            do { try await action() } catch { showError(error, from: controller) }
        }
    }
    static func episodeMenu(_ episode: PodcastEpisode, from controller: UIViewController) -> UIMenu {
        let library = PodcastLibraryController.shared
        let state = library.state.progress[episode.id] ?? PodcastEpisodeState()
        let downloads = PodcastDownloads.shared
        var actions: [UIMenuElement] = [
            UIAction(title: "Play", image: UIImage(systemName: "play.fill")) { _ in run(controller) { try await PodcastPlaybackController.shared.play(episode) } },
            UIAction(title: "Play Next", image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { _ in run(controller) { try library.requireStore().enqueue(episode.id, next: true); library.reloadState() } },
            UIAction(title: "Add to Queue", image: UIImage(systemName: "text.line.last.and.arrowtriangle.forward")) { _ in run(controller) { try library.requireStore().enqueue(episode.id, next: false); library.reloadState() } },
            UIAction(title: state.saved ? "Unsave Episode" : "Save Episode", image: UIImage(systemName: state.saved ? "bookmark.slash" : "bookmark")) { _ in run(controller) { try library.requireStore().saveEpisode(episode.id, !state.saved); library.reloadState(); await downloads.reconcile() } },
            UIAction(title: state.listened ? "Mark as Unplayed" : "Mark as Played", image: UIImage(systemName: state.listened ? "circle" : "checkmark.circle")) { _ in run(controller) { try library.requireStore().markListened(episode.id, !state.listened); library.reloadState(); await downloads.reconcile() } }
        ]
        if downloads.localURL(episode.id) != nil {
            actions.append(UIAction(title: "Remove Download", image: UIImage(systemName: "trash"), attributes: .destructive) { _ in downloads.remove(episode.id) })
        } else if downloads.downloads[episode.id]?.status == "downloading" {
            actions.append(UIAction(title: "Cancel Download", image: UIImage(systemName: "xmark.circle")) { _ in downloads.remove(episode.id) })
        } else {
            actions.append(UIAction(title: downloads.downloads[episode.id]?.status == "failed" ? "Retry Download" : "Download Episode", image: UIImage(systemName: "arrow.down.circle")) { _ in run(controller) { await downloads.download(episode) } })
        }
        actions += [
            UIAction(title: "Episode Details", image: UIImage(systemName: "info.circle")) { _ in controller.navigationController?.pushViewController(PodcastEpisodeViewController(episode: episode), animated: true) },
            UIAction(title: "Go to Show", image: UIImage(systemName: "dot.radiowaves.left.and.right")) { _ in controller.navigationController?.pushViewController(PodcastShowViewController(showID: episode.showID), animated: true) },
            UIAction(title: "Share Episode", image: UIImage(systemName: "square.and.arrow.up")) { _ in
                let activity = UIActivityViewController(activityItems: [episode.websiteURL ?? episode.mediaURL], applicationActivities: nil)
                activity.popoverPresentationController?.sourceView = controller.view
                activity.popoverPresentationController?.sourceRect = CGRect(x: controller.view.bounds.midX, y: controller.view.bounds.midY, width: 1, height: 1)
                controller.present(activity, animated: true)
            }
        ]
        return UIMenu(children: actions)
    }
}

@MainActor final class PodcastEpisodeCell: UITableViewCell {
    let artwork = UIImageView()
    let heading = UILabel(), detail = UILabel(), summary = UILabel()
    let more = UIButton(type: .system)
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        artwork.layer.cornerRadius = 8; artwork.clipsToBounds = true; artwork.backgroundColor = .secondarySystemBackground
        heading.font = .preferredFont(forTextStyle: .headline); heading.numberOfLines = 2
        detail.font = .preferredFont(forTextStyle: .caption1); detail.textColor = .secondaryLabel; detail.numberOfLines = 2
        summary.font = .preferredFont(forTextStyle: .subheadline); summary.textColor = .secondaryLabel; summary.numberOfLines = 2
        [heading, detail, summary].forEach { $0.adjustsFontForContentSizeCategory = true }
        let labels = UIStackView(arrangedSubviews: [detail, heading, summary]); labels.axis = .vertical; labels.spacing = 4
        more.setImage(UIImage(systemName: "ellipsis"), for: .normal); more.accessibilityLabel = "Episode Actions"; more.showsMenuAsPrimaryAction = true
        let stack = UIStackView(arrangedSubviews: [artwork, labels, more]); stack.spacing = 12; stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor), stack.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor), stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 14), stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -14), artwork.widthAnchor.constraint(equalToConstant: 64), artwork.heightAnchor.constraint(equalTo: artwork.widthAnchor), more.widthAnchor.constraint(equalToConstant: 44), more.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ episode: PodcastEpisode, owner: UIViewController) {
        let library = PodcastLibraryController.shared; let state = library.state.progress[episode.id]
        heading.text = episode.title; summary.text = PodcastUI.text(episode.summary)
        let date = episode.publishedAt == .distantPast ? "" : episode.publishedAt.formatted(date: .abbreviated, time: .omitted)
        let time = state?.listened == true ? "Played" : (state?.position ?? 0) > 0 ? "\(PodcastUI.time(max(0, episode.duration - (state?.position ?? 0)))) left" : PodcastUI.time(episode.duration)
        detail.text = [date, time, episode.explicit ? "Explicit" : nil, PodcastDownloads.shared.localURL(episode.id) != nil ? "Downloaded" : nil].compactMap { $0 }.joined(separator: " · ")
        let download = PodcastDownloads.shared.downloads[episode.id]
        if download?.status == "downloading" {
            let progress = PodcastDownloads.shared.progress[episode.id] ?? 0
            detail.text = (detail.text ?? "") + (progress > 0 ? " · Downloading \(Int(progress * 100))%" : " · Waiting to Download")
        } else if download?.status == "failed" { detail.text = (detail.text ?? "") + " · Download Failed — Retry in Episode Actions" }
        let player = PodcastPlaybackController.shared
        let buffering = player.currentEpisode?.id == episode.id && player.isBuffering
        if buffering {
            let spinner = UIActivityIndicatorView(style: .medium); spinner.startAnimating()
            spinner.accessibilityLabel = "Loading Audio"; spinner.accessibilityIdentifier = "podcasts.episodeLoading"
            accessoryView = spinner
        } else { accessoryView = nil }
        more.menu = PodcastUI.episodeMenu(episode, from: owner)
        PodcastUI.artwork(episode.artworkURL ?? library.state.shows[episode.showID]?.artworkURL, into: artwork)
        accessibilityIdentifier = "podcast.episode.\(episode.id)"
    }
}

@MainActor class PodcastListViewController: MusicScreenViewController, UITableViewDataSource, UITableViewDelegate, UITableViewDataSourcePrefetching {
    enum Row { case episode(PodcastEpisode), show(PodcastShow), action(String, String, () -> Void), directory(PodcastDirectoryResult) }
    struct Section { var title: String; var rows: [Row] }
    var sections: [Section] = []
    let podcasts = PodcastLibraryController.shared
    private(set) var openingDirectoryID: String?
    private(set) var directoryTask: Task<Void, Never>?
    private var directoryToken = UUID()
    private var loadingSubscriptions = Set<AnyCancellable>()
    private var prefetchTasks: [String: Task<Void, Never>] = [:]
    private let loadingSpinner = HorizonSpinnerView(side: 32)

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        cancelDirectoryOpening()
        cancelPrefetching()
    }

    func cancelPrefetching() {
        prefetchTasks.values.forEach { $0.cancel() }; prefetchTasks.removeAll()
    }
    func prefetch(_ results: [PodcastDirectoryResult]) {
        for result in results where prefetchTasks[result.collectionID] == nil {
            guard prefetchTasks.count < 3 else { break }
            prefetchTasks[result.collectionID] = Task { [weak self] in
                guard let self else { return }
                await podcasts.prefetch(result)
                prefetchTasks[result.collectionID] = nil
            }
        }
    }
    func tableView(_ tableView: UITableView, prefetchRowsAt indexPaths: [IndexPath]) {
        prefetch(indexPaths.compactMap { path in
            guard sections.indices.contains(path.section), sections[path.section].rows.indices.contains(path.row), case .directory(let result) = sections[path.section].rows[path.row] else { return nil }
            return result
        })
    }
    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        if case .directory(let result) = sections[indexPath.section].rows[indexPath.row] { prefetch([result]) }
    }
    func cancelDirectoryOpening() {
        directoryToken = UUID(); directoryTask?.cancel(); directoryTask = nil
        openingDirectoryID = nil
        table.allowsSelection = true
        table.reloadData()
    }

    func loading(_ label: String, atTop: Bool = false) {
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: table.bounds.width, height: 120))
        loadingSpinner.accessibilityLabel = label
        loadingSpinner.accessibilityIdentifier = "podcasts.loading"
        loadingSpinner.isAccessibilityElement = true
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(loadingSpinner)
        NSLayoutConstraint.activate([loadingSpinner.centerXAnchor.constraint(equalTo: footer.centerXAnchor), loadingSpinner.centerYAnchor.constraint(equalTo: footer.centerYAnchor)])
        loadingSpinner.startAnimating()
        if atTop { table.tableHeaderView = footer } else { table.tableFooterView = footer }
    }
    override func viewDidLoad() {
        super.viewDidLoad(); view.tintColor = .systemPurple
        navigationController?.navigationBar.prefersLargeTitles = true
        table.register(PodcastEpisodeCell.self, forCellReuseIdentifier: "episode")
        table.register(UITableViewCell.self, forCellReuseIdentifier: "podcastRow")
        table.dataSource = self; table.delegate = self; table.prefetchDataSource = self
        podcasts.$refreshingShowIDs.sink { [weak self] _ in DispatchQueue.main.async { self?.reload() } }.store(in: &loadingSubscriptions)
        PodcastDownloads.shared.objectWillChange.debounce(for: .milliseconds(200), scheduler: DispatchQueue.main).sink { [weak self] in self?.refreshVisibleEpisodes() }.store(in: &loadingSubscriptions)
        PodcastPlaybackController.shared.$isBuffering.sink { [weak self] _ in DispatchQueue.main.async { self?.refreshVisibleEpisodes() } }.store(in: &loadingSubscriptions)
        observe(.lunaPodcastsChanged) { [weak self] in self?.reload() }
        let refresh = UIRefreshControl(); refresh.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Task { await self.refreshContent(); refresh.endRefreshing(); self.reload() }
        }, for: .valueChanged); table.refreshControl = refresh
    }
    private func refreshVisibleEpisodes() {
        for path in table.indexPathsForVisibleRows ?? [] {
            guard sections.indices.contains(path.section), sections[path.section].rows.indices.contains(path.row), case .episode(let episode) = sections[path.section].rows[path.row], let cell = table.cellForRow(at: path) as? PodcastEpisodeCell else { continue }
            cell.configure(episode, owner: self)
        }
    }
    func refreshContent() async { await podcasts.refresh(force: true) }
    func reload() { table.reloadData() }
    func numberOfSections(in tableView: UITableView) -> Int { sections.count }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { sections[section].rows.count }
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { sections[section].title.isEmpty ? nil : sections[section].title }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = sections[indexPath.section].rows[indexPath.row]
        if case .episode(let episode) = row {
            let cell = tableView.dequeueReusableCell(withIdentifier: "episode", for: indexPath) as! PodcastEpisodeCell
            cell.configure(episode, owner: self); return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "podcastRow", for: indexPath)
        var content = cell.defaultContentConfiguration(); content.textProperties.numberOfLines = 2
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.imageProperties.maximumSize = CGSize(width: 56, height: 56); content.imageProperties.cornerRadius = 6
        cell.accessoryView = nil
        cell.accessoryType = .disclosureIndicator
        if case .directory(let result) = row, result.id == openingDirectoryID {
            let spinner = HorizonSpinnerView(side: 26)
            spinner.accessibilityLabel = "Loading Podcast"
            spinner.accessibilityIdentifier = "podcasts.opening"
            spinner.isAccessibilityElement = true
            spinner.startAnimating(); cell.accessoryView = spinner
        }
        var url: URL?
        switch row {
        case .show(let show): content.text = show.title; content.secondaryText = show.author; content.image = UIImage(systemName: "dot.radiowaves.left.and.right"); url = show.artworkURL
        case .directory(let result): content.text = result.episodeTitle ?? result.title; content.secondaryText = result.episodeTitle == nil ? result.author : result.title; content.image = UIImage(systemName: "dot.radiowaves.left.and.right"); url = result.artworkURL
        case .action(let title, let symbol, _): content.text = title; content.image = UIImage(systemName: symbol)
        case .episode: break
        }
        cell.accessibilityIdentifier = url?.absoluteString ?? content.text
        if let url, let image = PodcastUI.images.object(forKey: url as NSURL) { content.image = image }
        else if let url {
            Task { [weak cell] in
                guard let image = await PodcastUI.image(url) else { return }
                guard let cell, cell.accessibilityIdentifier == url.absoluteString, var current = cell.contentConfiguration as? UIListContentConfiguration else { return }
                current.image = image; cell.contentConfiguration = current
            }
        }
        cell.contentConfiguration = content; return cell
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard openingDirectoryID == nil else { return }
        switch sections[indexPath.section].rows[indexPath.row] {
        case .episode(let episode): PodcastUI.run(self) { try await PodcastPlaybackController.shared.play(episode) }
        case .show(let show): navigationController?.pushViewController(PodcastShowViewController(showID: show.id), animated: true)
        case .action(_, _, let action): action()
        case .directory(let result): openDirectory(result)
        }
    }
    func openDirectory(_ result: PodcastDirectoryResult) {
        guard openingDirectoryID == nil else { return }
        let token = UUID(); directoryToken = token
        openingDirectoryID = result.id; table.allowsSelection = false; table.reloadData()
        directoryTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if directoryToken == token {
                    openingDirectoryID = nil; directoryTask = nil
                    table.allowsSelection = true; table.reloadData()
                }
            }
            do {
                let destination = try await directoryDestination(result)
                guard !Task.isCancelled, directoryToken == token,
                      let navigation = navigationController,
                      navigation.topViewController === self || navigation.topViewController === parent else { return }
                navigation.pushViewController(destination, animated: true)
            } catch {
                guard !Task.isCancelled, directoryToken == token else { return }
                PodcastUI.showError(error, from: self)
            }
        }
    }
    func directoryDestination(_ result: PodcastDirectoryResult) async throws -> UIViewController {
        let directory = PodcastDirectory()
        var feed = result.feedURL
        if feed == nil { feed = try await directory.lookup([result.collectionID], country: podcasts.state.settings.countryCode).first?.feedURL }
        guard let feed else { throw PodcastError("This publisher does not make its RSS feed available to other podcast apps.") }
        let id = try await podcasts.addFeed(feed, follow: false, directoryID: result.collectionID)
        if let media = result.episodeURL, let episode = podcasts.episodes(for: id, applySettings: false).first(where: { $0.mediaURL == media }) {
            return PodcastEpisodeViewController(episode: episode)
        }
        return PodcastShowViewController(showID: id)
    }
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard case .episode(let episode) = sections[indexPath.section].rows[indexPath.row] else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in self.map { PodcastUI.episodeMenu(episode, from: $0) } }
    }
    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard case .episode(let episode) = sections[indexPath.section].rows[indexPath.row] else { return nil }
        let played = podcasts.state.progress[episode.id]?.listened == true
        let action = UIContextualAction(style: .normal, title: played ? "Unplayed" : "Played") { [weak self] _, _, done in
            do { try self?.podcasts.requireStore().markListened(episode.id, !played); self?.podcasts.reloadState(); done(true) }
            catch { if let self { PodcastUI.showError(error, from: self) }; done(false) }
        }; action.backgroundColor = .systemPurple
        return UISwipeActionsConfiguration(actions: [action])
    }
    func empty(_ title: String, detail: String, atTop: Bool = false, retry: (() -> Void)? = nil) {
        var content = UIContentUnavailableConfiguration.empty(); content.image = UIImage(systemName: "dot.radiowaves.left.and.right"); content.text = title; content.secondaryText = detail
        if let retry { content.button.title = "Try Again"; content.buttonProperties.primaryAction = UIAction { _ in retry() } }
        let view = UIContentUnavailableView(configuration: content); view.frame.size.height = 240
        if atTop { table.tableHeaderView = view } else { table.tableFooterView = view }
    }
}
