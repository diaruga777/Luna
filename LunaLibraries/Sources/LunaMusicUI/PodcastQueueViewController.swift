import UIKit
import Combine
import LunaPodcastCore
import LunaMusicCore

@MainActor final class PodcastQueueViewController: PodcastListViewController {
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Playing Next"; table.isEditing = true; table.allowsSelectionDuringEditing = true
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Clear", primaryAction: UIAction { [weak self] _ in guard let self else { return }; PodcastUI.run(self) { try self.podcasts.edit { $0.queue = []; $0.continuation = [] } } })
        reload()
    }
    override func reload() {
        let state = podcasts.state
        sections = [.init(title: "Queue", rows: state.queue.compactMap { state.episodes[$0] }.map(Row.episode)), .init(title: "Continue Playing", rows: state.continuation.compactMap { state.episodes[$0] }.map(Row.episode))]
        table.tableFooterView = nil
        if sections.allSatisfy({ $0.rows.isEmpty }) { empty("Your Queue Is Empty", detail: "Use Play Next or Add to Queue on an episode.") }
        super.reload()
    }
    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }
    func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        do { try podcasts.edit { state in
            var lists = [state.queue, state.continuation]; let id = lists[source.section].remove(at: source.row)
            lists[destination.section].insert(id, at: min(destination.row, lists[destination.section].count)); state.queue = lists[0]; state.continuation = lists[1]
        } } catch { PodcastUI.showError(error, from: self) }; reload()
    }
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        do { try podcasts.edit { state in if indexPath.section == 0 { state.queue.remove(at: indexPath.row) } else { state.continuation.remove(at: indexPath.row) } } }
        catch { PodcastUI.showError(error, from: self) }; reload()
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard case .episode(let episode) = sections[indexPath.section].rows[indexPath.row] else { return }
        PodcastUI.run(self) { try await PodcastPlaybackController.shared.play(episode, continueShow: false) }
    }
}
@MainActor final class PodcastTranscriptViewController: UITableViewController, UISearchResultsUpdating {
    private let search = UISearchController(searchResultsController: nil)
    private var subscriptions = Set<AnyCancellable>()
    private var cues: [PodcastTranscriptCue] = []
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Transcript"; tableView.rowHeight = UITableView.automaticDimension; tableView.estimatedRowHeight = 90
        search.searchResultsUpdater = self; search.obscuresBackgroundDuringPresentation = false; search.searchBar.placeholder = "Search Transcript"; navigationItem.searchController = search
        PodcastPlaybackController.shared.$transcript.sink { [weak self] _ in DispatchQueue.main.async { self?.reload() } }.store(in: &subscriptions)
        reload()
    }
    func updateSearchResults(for searchController: UISearchController) { reload() }
    private func reload() {
        let query = search.searchBar.text ?? ""
        cues = PodcastPlaybackController.shared.transcript.filter { query.isEmpty || $0.text.localizedStandardContains(query) }
        if cues.isEmpty { var configuration = UIContentUnavailableConfiguration.empty(); configuration.text = "No Transcript"; configuration.secondaryText = query.isEmpty ? "This episode has no available publisher transcript." : "No transcript text matches your search."; tableView.backgroundView = UIContentUnavailableView(configuration: configuration) }
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
        super.viewDidLoad(); title = "Chapters"
        PodcastPlaybackController.shared.$chapters.sink { [weak self] _ in DispatchQueue.main.async { self?.reload() } }.store(in: &subscriptions); reload()
    }
    private func reload() {
        if chapters.isEmpty { var content = UIContentUnavailableConfiguration.empty(); content.text = "No Chapters"; content.secondaryText = "The publisher has not supplied chapters for this episode."; tableView.backgroundView = UIContentUnavailableView(configuration: content) }
        else { tableView.backgroundView = nil }; tableView.reloadData()
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { chapters.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let chapter = chapters[indexPath.row], cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration(); content.text = chapter.title; content.secondaryText = PodcastUI.time(chapter.start); cell.contentConfiguration = content; return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) { PodcastPlaybackController.shared.seek(to: chapters[indexPath.row].start) }
}
