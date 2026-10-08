import UIKit
import LunaPodcastCore
import LunaMusicCore
import LunaDesignSystem

@MainActor enum PodcastUI {
    static let images = NSCache<NSURL, UIImage>()
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
            guard let (data, response) = try? await URLSession.shared.data(from: url), (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count < 15_000_000, let image = UIImage(data: data) else { return }
            images.setObject(image, forKey: url as NSURL)
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
        Task { do { try await action() } catch { showError(error, from: controller) } }
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
            actions.append(UIAction(title: downloads.downloads[episode.id]?.status == "failed" ? "Retry Download" : "Download Episode", image: UIImage(systemName: "arrow.down.circle")) { _ in Task { await downloads.download(episode) } })
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
        more.menu = PodcastUI.episodeMenu(episode, from: owner)
        PodcastUI.artwork(episode.artworkURL ?? library.state.shows[episode.showID]?.artworkURL, into: artwork)
        accessibilityIdentifier = "podcast.episode.\(episode.id)"
    }
}

@MainActor class PodcastListViewController: MusicScreenViewController, UITableViewDataSource, UITableViewDelegate {
    enum Row { case episode(PodcastEpisode), show(PodcastShow), action(String, String, () -> Void), directory(PodcastDirectoryResult) }
    struct Section { var title: String; var rows: [Row] }
    var sections: [Section] = []
    let podcasts = PodcastLibraryController.shared
    private(set) var openingDirectoryID: String?
    private(set) var directoryTask: Task<Void, Never>?
    private var directoryToken = UUID()
    private let loadingSpinner = HorizonSpinnerView(side: 32)

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        cancelDirectoryOpening()
    }

    func cancelDirectoryOpening() {
        directoryToken = UUID(); directoryTask?.cancel(); directoryTask = nil
        openingDirectoryID = nil
        table.allowsSelection = true
        table.reloadData()
    }

    func loading(_ label: String) {
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: table.bounds.width, height: 120))
        loadingSpinner.accessibilityLabel = label
        loadingSpinner.accessibilityIdentifier = "podcasts.loading"
        loadingSpinner.isAccessibilityElement = true
        loadingSpinner.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(loadingSpinner)
        NSLayoutConstraint.activate([loadingSpinner.centerXAnchor.constraint(equalTo: footer.centerXAnchor), loadingSpinner.centerYAnchor.constraint(equalTo: footer.centerYAnchor)])
        loadingSpinner.startAnimating()
        table.tableFooterView = footer
    }
    override func viewDidLoad() {
        super.viewDidLoad(); view.tintColor = .systemPurple
        navigationController?.navigationBar.prefersLargeTitles = true
        table.register(PodcastEpisodeCell.self, forCellReuseIdentifier: "episode")
        table.register(UITableViewCell.self, forCellReuseIdentifier: "podcastRow")
        table.dataSource = self; table.delegate = self
        observe(.lunaPodcastsChanged) { [weak self] in self?.reload() }
        let refresh = UIRefreshControl(); refresh.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            Task { await self.podcasts.refresh(force: true); refresh.endRefreshing(); self.reload() }
        }, for: .valueChanged); table.refreshControl = refresh
    }
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
                guard let (data, _) = try? await URLSession.shared.data(from: url), data.count < 15_000_000, let image = UIImage(data: data) else { return }
                PodcastUI.images.setObject(image, forKey: url as NSURL)
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
    func empty(_ title: String, detail: String) {
        var content = UIContentUnavailableConfiguration.empty(); content.image = UIImage(systemName: "dot.radiowaves.left.and.right"); content.text = title; content.secondaryText = detail
        let view = UIContentUnavailableView(configuration: content); view.frame.size.height = 240
        table.tableFooterView = view
    }
}
