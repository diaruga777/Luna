import UIKit
import Combine
import LunaPodcastCore
import LunaMusicCore

/// Embedded in the player's upper stage, without a second navigation bar or
/// mini player. Editing reserves only the reorder handle, not a delete column.
@MainActor final class PodcastQueueViewController: UIViewController, UITableViewDataSource, UITableViewDelegate {
    let table = UITableView(frame: .zero, style: .plain)
    private let library: PodcastLibraryController
    private let heading = UILabel()
    private let clear = UIButton(type: .system)
    private let empty = UILabel()
    private var episodes: [PodcastEpisode] = []
    private var subscriptions = Set<AnyCancellable>()

    init(library: PodcastLibraryController = .shared) {
        self.library = library; super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        heading.text = "Queue"; heading.font = MusicStyle.font(22, weight: .semibold)
        clear.setTitle("Clear", for: .normal); clear.titleLabel?.font = MusicStyle.font(22)
        clear.tintColor = UIColor.white.withAlphaComponent(0.5); clear.accessibilityLabel = "Clear Queue"
        clear.addAction(UIAction { [weak self] _ in self?.edit { $0.queue = []; $0.continuation = [] } }, for: .touchUpInside)
        empty.text = "Your Queue Is Empty"; empty.font = MusicStyle.font(18); empty.textColor = UIColor.white.withAlphaComponent(0.5)
        empty.numberOfLines = 0
        [heading, empty].forEach { $0.adjustsFontForContentSizeCategory = true }
        table.backgroundColor = .clear; table.separatorStyle = .none
        table.contentInsetAdjustmentBehavior = .never; table.sectionHeaderTopPadding = 0
        table.dataSource = self; table.delegate = self
        table.rowHeight = UITableView.automaticDimension; table.estimatedRowHeight = 72
        table.register(PodcastPlayerQueueCell.self, forCellReuseIdentifier: "episode")
        table.setEditing(true, animated: false); table.allowsSelectionDuringEditing = true
        table.accessibilityLabel = "Upcoming Episodes"
        [heading, clear, table, empty].forEach(view.addSubview)
        library.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.reload() } }.store(in: &subscriptions)
        reload()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let headerHeight = max(44, heading.font.lineHeight + 12)
        heading.frame = CGRect(x: 0, y: 0, width: max(0, view.bounds.width - 85), height: headerHeight)
        clear.frame = CGRect(x: view.bounds.width - 80, y: 0, width: 80, height: headerHeight)
        table.frame = CGRect(x: 0, y: headerHeight + 8, width: view.bounds.width, height: max(0, view.bounds.height - headerHeight - 8))
        empty.frame = CGRect(x: 0, y: headerHeight + 20, width: view.bounds.width, height: empty.sizeThatFits(CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude)).height)
    }
    private func reload() {
        episodes = library.state.queue.compactMap { library.state.episodes[$0] }
        empty.isHidden = !episodes.isEmpty; clear.isEnabled = !episodes.isEmpty; table.reloadData()
    }
    private func edit(_ action: (inout PodcastLibraryState) -> Void) {
        do { try library.edit(action) } catch { PodcastUI.showError(error, from: parent ?? self) }
        reload()
    }
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { episodes.count }
    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let episode = episodes[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "episode", for: indexPath) as! PodcastPlayerQueueCell
        cell.configure(episode, progress: library.state.progress[episode.id], artworkURL: episode.artworkURL ?? library.state.shows[episode.showID]?.artworkURL)
        cell.accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Remove from Queue", actionHandler: { [weak self] _ in
            self?.edit { $0.queue.removeAll { $0 == episode.id } }; return true
        })]
        return cell
    }
    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle { .none }
    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool { false }
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }
    func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        let id = episodes[source.row].id, targetID = episodes[destination.row].id
        edit { state in
            guard let from = state.queue.firstIndex(of: id), let to = state.queue.firstIndex(of: targetID) else { return }
            state.queue.remove(at: from); state.queue.insert(id, at: min(to, state.queue.count))
        }
    }
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let episode = episodes[indexPath.row]
        PodcastUI.run(parent ?? self) { try await PodcastPlaybackController.shared.play(episode) }
    }
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let episode = episodes[indexPath.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            let remove = UIAction(title: "Remove from Queue", image: UIImage(systemName: "minus.circle"), attributes: .destructive) { [weak self] _ in self?.edit { $0.queue.removeAll { $0 == episode.id } } }
            return UIMenu(children: [remove] + PodcastUI.episodeMenu(episode, from: self.parent ?? self).children)
        }
    }
}

@MainActor final class PodcastPlayerQueueCell: UITableViewCell {
    let artwork = UIImageView()
    let heading = PodcastPlayerTitleView()
    let detail = UILabel()
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear; contentView.backgroundColor = .clear
        artwork.layer.cornerRadius = 4; artwork.clipsToBounds = true; artwork.backgroundColor = .secondarySystemBackground
        heading.font = MusicStyle.font(20); detail.font = MusicStyle.font(18)
        heading.textColor = .white; detail.textColor = UIColor.white.withAlphaComponent(0.5)
        heading.adjustsFontForContentSizeCategory = true
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.numberOfLines = 1; detail.lineBreakMode = .byTruncatingTail; detail.adjustsFontForContentSizeCategory = true
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let labels = UIStackView(arrangedSubviews: [heading, detail]); labels.axis = .vertical; labels.spacing = 4
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = UIStackView(arrangedSubviews: [artwork, labels]); stack.alignment = .center; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8), stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            artwork.widthAnchor.constraint(equalToConstant: 48), artwork.heightAnchor.constraint(equalTo: artwork.widthAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func configure(_ episode: PodcastEpisode, progress: PodcastEpisodeState?, artworkURL: URL?) {
        heading.text = episode.title
        let sameYear = Calendar.current.isDate(episode.publishedAt, equalTo: Date(), toGranularity: .year)
        let date = episode.publishedAt == .distantPast ? nil : episode.publishedAt.formatted(sameYear ? .dateTime.month(.wide).day() : .dateTime.month(.wide).day().year())
        let seconds = max(0, episode.duration - (progress?.position ?? 0))
        let minutes = Int(seconds / 60)
        let duration = minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : minutes > 0 ? "\(minutes)m" : "\(Int(seconds))s"
        let status = progress?.listened == true ? "Played" : duration + ((progress?.position ?? 0) > 0 ? " left" : "")
        detail.text = [date, status].compactMap { $0 }.joined(separator: " · ")
        PodcastUI.artwork(artworkURL, into: artwork)
        accessibilityLabel = [episode.title, detail.text].compactMap { $0 }.joined(separator: ", ")
    }
}
@MainActor final class PodcastTranscriptViewController: UITableViewController, UISearchResultsUpdating {
    private let search = UISearchController(searchResultsController: nil)
    private var subscriptions = Set<AnyCancellable>()
    private var cues: [PodcastTranscriptCue] = []
    override func viewDidLoad() {
        super.viewDidLoad(); PodcastPlaybackController.shared.prepareExtras(); title = "Transcript"; tableView.rowHeight = UITableView.automaticDimension; tableView.estimatedRowHeight = 90
        search.searchResultsUpdater = self; search.obscuresBackgroundDuringPresentation = false; search.searchBar.placeholder = "Search Transcript"; navigationItem.searchController = search
        let player = PodcastPlaybackController.shared
        player.$transcript.map { _ in () }.merge(with: player.$isLoadingTranscript.map { _ in () }, player.$transcriptError.map { _ in () })
            .receive(on: DispatchQueue.main).sink { [weak self] in self?.reload() }.store(in: &subscriptions)
        reload()
    }
    func updateSearchResults(for searchController: UISearchController) { reload() }
    private func reload() {
        let query = search.searchBar.text ?? ""
        cues = PodcastPlaybackController.shared.transcript.filter { query.isEmpty || $0.text.localizedStandardContains(query) }
        if PodcastPlaybackController.shared.isLoadingTranscript { tableView.backgroundView = PodcastUI.supplementaryState(loading: true, error: nil, title: "Loading Transcript") }
        else if let error = PodcastPlaybackController.shared.transcriptError { tableView.backgroundView = PodcastUI.supplementaryState(loading: false, error: error, title: "Unable to Load Transcript") }
        else if cues.isEmpty { var configuration = UIContentUnavailableConfiguration.empty(); configuration.text = "No Transcript"; configuration.secondaryText = query.isEmpty ? "This episode has no available publisher transcript." : "No transcript text matches your search."; tableView.backgroundView = UIContentUnavailableView(configuration: configuration) }
        else { tableView.backgroundView = nil }
        tableView.reloadData()
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { cues.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cue = cues[indexPath.row], cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration(); content.text = cue.text; content.textProperties.numberOfLines = 0
        content.textProperties.font = .preferredFont(forTextStyle: .title3); content.secondaryText = cue.end > 0 ? PodcastUI.time(cue.start) : nil
        let position = PodcastPlaybackController.shared.position
        content.textProperties.color = cue.end > cue.start && (cue.start..<cue.end).contains(position) ? .systemPurple : .label
        cell.contentConfiguration = content; return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { let cue = cues[indexPath.row]; if cue.end > 0 { PodcastPlaybackController.shared.seek(to: cue.start) } }
}
@MainActor final class PodcastChaptersViewController: UITableViewController {
    private var chapters: [PodcastChapter] { PodcastPlaybackController.shared.chapters }
    private var subscriptions = Set<AnyCancellable>()
    override func viewDidLoad() {
        super.viewDidLoad(); PodcastPlaybackController.shared.prepareExtras(); title = "Chapters"
        let player = PodcastPlaybackController.shared
        player.$chapters.map { _ in () }.merge(with: player.$isLoadingChapters.map { _ in () }, player.$chaptersError.map { _ in () })
            .receive(on: DispatchQueue.main).sink { [weak self] in self?.reload() }.store(in: &subscriptions)
        reload()
    }
    private func reload() {
        if PodcastPlaybackController.shared.isLoadingChapters { tableView.backgroundView = PodcastUI.supplementaryState(loading: true, error: nil, title: "Loading Chapters") }
        else if let error = PodcastPlaybackController.shared.chaptersError { tableView.backgroundView = PodcastUI.supplementaryState(loading: false, error: error, title: "Unable to Load Chapters") }
        else if chapters.isEmpty { var content = UIContentUnavailableConfiguration.empty(); content.text = "No Chapters"; content.secondaryText = "The publisher has not supplied chapters for this episode."; tableView.backgroundView = UIContentUnavailableView(configuration: content) }
        else { tableView.backgroundView = nil }; tableView.reloadData()
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { chapters.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let chapter = chapters[indexPath.row], cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration(); content.text = chapter.title; content.secondaryText = PodcastUI.time(chapter.start); cell.contentConfiguration = content; return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { PodcastPlaybackController.shared.seek(to: chapters[indexPath.row].start) }
}

@MainActor private extension PodcastUI {
    static func supplementaryState(loading: Bool, error: String?, title: String) -> UIView {
        var content = loading ? UIContentUnavailableConfiguration.loading() : UIContentUnavailableConfiguration.empty()
        content.text = title; content.secondaryText = error
        if !loading { content.button.title = "Try Again"; content.buttonProperties.primaryAction = UIAction { _ in PodcastPlaybackController.shared.retryExtras() } }
        return UIContentUnavailableView(configuration: content)
    }
}
