import UIKit
import LunaPodcastCore
import LunaMusicCore

@MainActor final class PodcastShowViewController: PodcastListViewController, UISearchResultsUpdating {
    let showID: String
    private let search = UISearchController(searchResultsController: nil)
    private let filter = UISegmentedControl(items: ["All", "Unplayed", "Downloaded", "Saved"])
    private var header: UIView?
    init(showID: String) { self.showID = showID; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        search.searchResultsUpdater = self; search.obscuresBackgroundDuringPresentation = false; search.searchBar.placeholder = "Episodes"
        navigationItem.searchController = search
        filter.selectedSegmentIndex = 0; filter.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
        reload(); Task { await podcasts.refresh(showIDs: [showID], force: true) }
    }
    func updateSearchResults(for searchController: UISearchController) { reload() }
    override func reload() {
        guard isViewLoaded, let show = podcasts.state.shows[showID] else { return }
        title = show.title
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: UIMenu(children: [
                UIAction(title: "Settings", image: UIImage(systemName: "gearshape")) { [weak self] _ in guard let self else { return }; navigationController?.pushViewController(PodcastSettingsViewController(showID: showID), animated: true) },
                UIAction(title: "Mark All as Played", image: UIImage(systemName: "checkmark.circle")) { [weak self] _ in
                    guard let self else { return }; PodcastUI.run(self) {
                        for episode in self.podcasts.episodes(for: self.showID, applySettings: false).reversed() { try self.podcasts.requireStore().markListened(episode.id, true) }
                        self.podcasts.reloadState()
                    }
                },
                UIAction(title: "Share Show", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in
                    guard let self else { return }; let activity = UIActivityViewController(activityItems: [show.websiteURL ?? show.feedURL], applicationActivities: nil)
                    activity.popoverPresentationController?.barButtonItem = self.navigationItem.rightBarButtonItems?.first
                    self.present(activity, animated: true)
                }
            ])),
            UIBarButtonItem(title: show.followed ? "Following" : "Follow", primaryAction: UIAction { [weak self] _ in guard let self else { return }; PodcastUI.run(self) { try self.podcasts.setFollowed(self.showID, !show.followed) } })
        ]
        let query = search.searchBar.text ?? ""
        let episodes = podcasts.episodes(for: showID).filter { episode in
            let state = podcasts.state.progress[episode.id]
            guard query.isEmpty || episode.title.localizedStandardContains(query) || PodcastUI.text(episode.summary).localizedStandardContains(query) else { return false }
            switch filter.selectedSegmentIndex { case 1: return state?.listened != true; case 2: return PodcastDownloads.shared.localURL(episode.id) != nil; case 3: return state?.saved == true; default: return true }
        }
        sections = [.init(title: "Episodes", rows: episodes.map(Row.episode))]
        buildHeader(show)
        table.tableFooterView = nil
        if episodes.isEmpty { empty("No Episodes", detail: show.refreshError ?? "No episodes match this filter.") }
        super.reload()
    }
    private func buildHeader(_ show: PodcastShow) {
        let art = UIImageView(); art.layer.cornerRadius = 12; art.clipsToBounds = true
        PodcastUI.artwork(show.artworkURL, into: art)
        let name = UILabel(); name.font = .preferredFont(forTextStyle: .title1); name.text = show.title; name.numberOfLines = 0
        let author = UILabel(); author.font = .preferredFont(forTextStyle: .subheadline); author.textColor = .secondaryLabel; author.text = show.author; author.numberOfLines = 0
        let description = UILabel(); description.font = .preferredFont(forTextStyle: .body); description.textColor = .secondaryLabel; description.numberOfLines = 4; description.text = PodcastUI.text(show.summary)
        [name, author, description].forEach { $0.adjustsFontForContentSizeCategory = true }
        let play = UIButton(configuration: .tinted()); play.configuration?.title = "Play"; play.configuration?.image = UIImage(systemName: "play.fill"); play.configuration?.imagePadding = 8
        play.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let episodes = self.podcasts.episodes(for: self.showID).filter { self.podcasts.state.progress[$0.id]?.listened != true }
            PodcastUI.run(self) { try await PodcastPlaybackController.shared.playEpisodes(episodes) }
        }, for: .touchUpInside)
        let labels = UIStackView(arrangedSubviews: [name, author]); labels.axis = .vertical; labels.spacing = 6
        let row = UIStackView(arrangedSubviews: [art, labels]); row.spacing = 18; row.alignment = .center
        let stack = UIStackView(arrangedSubviews: [row, description, play, filter]); stack.axis = .vertical; stack.spacing = 16
        stack.isLayoutMarginsRelativeArrangement = true; stack.directionalLayoutMargins = .init(top: 20, leading: 20, bottom: 20, trailing: 20)
        NSLayoutConstraint.activate([art.widthAnchor.constraint(equalToConstant: 110), art.heightAnchor.constraint(equalTo: art.widthAnchor), play.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)])
        header = stack; table.tableHeaderView = stack; layoutHeader()
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); layoutHeader() }
    private func layoutHeader() {
        guard let header else { return }
        let size = header.systemLayoutSizeFitting(CGSize(width: table.bounds.width, height: 0), withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        if abs(header.frame.height - size.height) > 1 || header.frame.width != table.bounds.width { header.frame = CGRect(x: 0, y: 0, width: table.bounds.width, height: size.height); table.tableHeaderView = header }
    }
}

@MainActor final class PodcastEpisodeViewController: UIViewController {
    let episode: PodcastEpisode
    init(episode: PodcastEpisode) { self.episode = episode; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Episode"; view.backgroundColor = .systemBackground; view.tintColor = .systemPurple
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: PodcastUI.episodeMenu(episode, from: self))
        let text = UITextView(); text.isEditable = false; text.dataDetectorTypes = [.link]; text.backgroundColor = .clear
        text.font = .preferredFont(forTextStyle: .body); text.adjustsFontForContentSizeCategory = true
        text.text = "\(episode.title)\n\n\(PodcastLibraryController.shared.state.shows[episode.showID]?.title ?? "")\n\(episode.publishedAt.formatted(date: .long, time: .omitted)) · \(PodcastUI.time(episode.duration))\n\n\(PodcastUI.text(episode.summary))"
        let play = UIButton(configuration: .tinted()); play.configuration?.title = "Play Episode"; play.configuration?.image = UIImage(systemName: "play.fill"); play.configuration?.imagePadding = 8
        play.addAction(UIAction { [weak self] _ in guard let self else { return }; PodcastUI.run(self) { try await PodcastPlaybackController.shared.play(self.episode) } }, for: .touchUpInside)
        let stack = UIStackView(arrangedSubviews: [play, text]); stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20), stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20), stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12), stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor), play.heightAnchor.constraint(greaterThanOrEqualToConstant: 48)])
    }
}

@MainActor final class PodcastStationViewController: PodcastListViewController {
    let id: String
    init(id: String) { self.id = id; super.init(nibName: nil, bundle: nil) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItems = [UIBarButtonItem(image: UIImage(systemName: "gearshape"), primaryAction: UIAction { [weak self] _ in guard let self else { return }; navigationController?.pushViewController(PodcastStationSettingsViewController(id: id), animated: true) }), UIBarButtonItem(image: UIImage(systemName: "play.fill"), primaryAction: UIAction { [weak self] _ in
            guard let self, let station = podcasts.state.stations.first(where: { $0.id == self.id }) else { return }
            PodcastUI.run(self) { try await PodcastPlaybackController.shared.playEpisodes(PodcastPolicies.stationEpisodes(station, state: self.podcasts.state)) }
        })]; reload()
    }
    override func reload() {
        guard let station = podcasts.state.stations.first(where: { $0.id == id }) else { return }
        title = station.name; sections = [.init(title: "", rows: PodcastPolicies.stationEpisodes(station, state: podcasts.state).map(Row.episode))]; super.reload()
    }
}
