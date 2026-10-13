import UIKit
import Combine
import UniformTypeIdentifiers
import LunaPodcastCore
import LunaMusicCore

@MainActor final class PodcastSettingsViewController: UITableViewController, UIDocumentPickerDelegate {
    private let library = PodcastLibraryController.shared
    private let showID: String?
    private var groups: [(String, [Setting])] = []
    private enum Setting { case toggle(String, Bool, (Bool) async throws -> Void), choice(String, String, [(String, () async throws -> Void)]), action(String, () async throws -> Void) }
    init(showID: String? = nil) { self.showID = showID; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() { super.viewDidLoad(); title = showID == nil ? "Podcast Settings" : "Show Settings"; view.tintColor = .systemPurple; reload() }
    private func reload() {
        let state = library.state
        if let id = showID, let show = state.shows[id] {
            groups = [("\(show.title)", [
                .toggle("Follow Show", show.followed) { [self] value in try library.setFollowed(id, value) },
                .toggle("New Episode Notifications", show.settings.notifications) { [self] value in try await library.setNotifications(id, value) },
                .toggle("Hide Played Episodes", show.settings.hidePlayed) { [self] value in try editShow { $0.hidePlayed = value } },
                .choice("Episode Order", show.settings.newestFirst ? "Newest First" : "Oldest First", [("Newest First", { [self] in try editShow { $0.newestFirst = true } }), ("Oldest First", { [self] in try editShow { $0.newestFirst = false } })]),
                .choice("Automatically Download", limitName(show.settings.automaticDownloadLimit), [0, 1, 2, 3, 5, 10, -1].map { limit in (limitName(limit), { [self] in try editShow { $0.automaticDownloadLimit = limit }; await PodcastDownloads.shared.reconcile() }) }),
                .choice("Playback Speed", "\(show.settings.playbackRate)×", [Float(0.5), 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3].map { value in ("\(value)×", { [self] in try editShow { $0.playbackRate = value }; if PodcastPlaybackController.shared.currentEpisode?.showID == id { PodcastPlaybackController.shared.setRate(value) } }) })
            ])]
        } else {
            groups = [("Playback", [
                .choice("Skip Back", "\(Int(state.settings.skipBack)) seconds", [5, 10, 15, 30, 45, 60].map { value in ("\(value) seconds", { [self] in try library.edit { $0.settings.skipBack = Double(value) } }) }),
                .choice("Skip Forward", "\(Int(state.settings.skipForward)) seconds", [5, 10, 15, 30, 45, 60].map { value in ("\(value) seconds", { [self] in try library.edit { $0.settings.skipForward = Double(value) } }) }),
                .toggle("Hide Played Episodes", state.settings.hidePlayed) { [self] value in try library.edit { $0.settings.hidePlayed = value } },
                .toggle("Stream over Cellular", state.settings.cellularStreaming) { [self] value in try library.edit { $0.settings.cellularStreaming = value } }
            ]), ("Downloads", [
                .choice("Download Size Limit", ByteCountFormatter.string(fromByteCount: state.settings.maximumDownloadBytes, countStyle: .file), [Int64(500_000_000), 1_000_000_000, 2_000_000_000, 5_000_000_000, 10_000_000_000].map { bytes in
                    (ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), { [self] in try library.edit { $0.settings.downloadByteLimit = bytes }; await PodcastDownloads.shared.reconcile() })
                }),
                .toggle("Download over Cellular", state.settings.cellularDownloads) { [self] value in try library.edit { $0.settings.cellularDownloads = value } },
                .toggle("Download Saved Episodes", state.settings.downloadSavedEpisodes) { [self] value in try library.edit { $0.settings.downloadSavedEpisodes = value }; await PodcastDownloads.shared.reconcile() },
                .toggle("Remove Played Downloads", state.settings.removePlayedDownloads) { [self] value in try library.edit { $0.settings.removePlayedDownloads = value }; await PodcastDownloads.shared.reconcile() },
                .choice("Remove Played After", "\(Int(state.settings.playedRetentionHours)) hours", [0, 24, 48, 168].map { value in (value == 0 ? "Immediately" : "\(value) hours", { [self] in try library.edit { $0.settings.playedRetentionHours = Double(value) }; await PodcastDownloads.shared.reconcile() }) }),
                .action("Manage Downloads · \(ByteCountFormatter.string(fromByteCount: PodcastDownloads.shared.totalBytes, countStyle: .file))") { [self] in navigationController?.pushViewController(PodcastDownloadSettingsViewController(), animated: true) }
            ]), ("Library", [
                .toggle("Sync Library with iCloud", state.settings.syncEnabled) { [self] value in try library.edit { $0.settings.syncEnabled = value }; if value { try await PodcastCloudSync.shared.synchronize() } },
                .action("Sync Now") { try await PodcastCloudSync.shared.synchronize() },
                .action("Refresh All Shows") { [self] in await library.refresh(force: true) },
                .action("Import Shows (OPML)") { [self] in let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.xml, .data], asCopy: true); picker.delegate = self; present(picker, animated: true) },
                .action("Export Followed Shows") { [self] in
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Luna Podcasts.opml")
                    try PodcastOPML.export(Array(library.state.shows.values)).write(to: url, options: [.atomic])
                    let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil); controller.popoverPresentationController?.sourceView = view
                    controller.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1); present(controller, animated: true)
                }
            ])]
        }
        tableView.reloadData()
    }
    private func editShow(_ edit: (inout PodcastShowSettings) -> Void) throws {
        guard let id = showID else { return }
        try library.edit { state in guard var show = state.shows[id] else { return }; edit(&show.settings); show.updatedAt = Date(); state.shows[id] = show }
    }
    private func limitName(_ limit: Int) -> String { limit < 0 ? "All Unplayed" : limit == 0 ? "Off" : "Latest \(limit)" }
    override func numberOfSections(in tableView: UITableView) -> Int { groups.count }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { groups[section].1.count }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { groups[section].0 }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var configuration = cell.defaultContentConfiguration(); configuration.textProperties.numberOfLines = 0
        switch groups[indexPath.section].1[indexPath.row] {
        case .toggle(let title, let enabled, let action):
            configuration.text = title; let toggle = UISwitch(); toggle.isOn = enabled; toggle.accessibilityLabel = title
            toggle.addAction(UIAction { [weak self, weak toggle] _ in guard let self, let toggle else { return }; self.perform { try await action(toggle.isOn) } }, for: .valueChanged); cell.accessoryView = toggle
        case .choice(let title, let value, _): configuration.text = title; configuration.secondaryText = value; cell.accessoryType = .disclosureIndicator
        case .action(let title, _): configuration.text = title; cell.accessoryType = .disclosureIndicator
        }
        cell.contentConfiguration = configuration; return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch groups[indexPath.section].1[indexPath.row] {
        case .toggle: break
        case .action(_, let action): perform(action)
        case .choice(let title, _, let values):
            let alert = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
            for (label, action) in values { alert.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in self?.perform(action) }) }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath); present(alert, animated: true)
        }
    }
    private func perform(_ action: @escaping () async throws -> Void) { PodcastUI.run(self) { defer { self.reload() }; try await action() } }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        perform { [self] in
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let feeds = try PodcastOPML.urls(Data(contentsOf: url)); var failures: [String] = []
            for feed in feeds { do { try await library.addFeed(feed) } catch { failures.append(feed.host ?? "Feed") } }
            if !failures.isEmpty { throw PodcastError("Imported available shows. Could not import: \(failures.joined(separator: ", ")).") }
        }
    }
}
@MainActor final class PodcastDownloadSettingsViewController: UITableViewController {
    private var subscriptions = Set<AnyCancellable>()
    private var ids: [String] { PodcastDownloads.shared.downloads.keys.sorted() }
    override func viewDidLoad() {
        super.viewDidLoad(); title = "Downloads"; tableView.rowHeight = UITableView.automaticDimension
        PodcastDownloads.shared.objectWillChange.debounce(for: .milliseconds(200), scheduler: DispatchQueue.main).sink { [weak self] in self?.tableView.reloadData() }.store(in: &subscriptions)
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { ids.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let id = ids[indexPath.row], record = PodcastDownloads.shared.downloads[id]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration(); content.text = PodcastLibraryController.shared.state.episodes[id]?.title ?? "Episode"; content.textProperties.numberOfLines = 2
        content.secondaryText = record?.error ?? "\(record?.status.capitalized ?? "") · \(ByteCountFormatter.string(fromByteCount: record?.bytes ?? 0, countStyle: .file))"
        content.secondaryTextProperties.numberOfLines = 0; cell.contentConfiguration = content; return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        let id = ids[indexPath.row]
        if let episode = PodcastLibraryController.shared.state.episodes[id] { Task { await PodcastDownloads.shared.download(episode); tableView.reloadData() } }
    }
    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) { PodcastDownloads.shared.remove(ids[indexPath.row]); tableView.reloadData() }
}
@MainActor final class PodcastStationSettingsViewController: UITableViewController {
    let id: String
    private let library = PodcastLibraryController.shared
    private var station: PodcastStation? { library.state.stations.first { $0.id == id } }
    private var shows: [PodcastShow] { library.state.shows.values.filter(\.followed).sorted { $0.title < $1.title } }
    init(id: String) { self.id = id; super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() { super.viewDidLoad(); title = "Station Settings" }
    override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { section == 0 ? 6 : section == 1 ? shows.count : 1 }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? { section == 1 ? "Choose Shows" : nil }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        guard let station else { return cell }
        if indexPath.section == 0 {
            let titles = ["Name", "Include All Shows", "Unplayed Only", "Newest First", "Episodes per Show", "Media"]
            cell.textLabel?.text = titles[indexPath.row]
            if (1...3).contains(indexPath.row) {
                let value = [station.allShows, station.unplayedOnly, station.newestFirst][indexPath.row - 1]
                cell.accessoryType = value ? .checkmark : .none
            } else { cell.detailTextLabel?.text = indexPath.row == 0 ? station.name : indexPath.row == 4 ? (station.episodesPerShow == 0 ? "All" : "\(station.episodesPerShow)") : station.media.capitalized }
        } else if indexPath.section == 1 { cell.textLabel?.text = shows[indexPath.row].title; cell.accessoryType = station.allShows || station.showIDs.contains(shows[indexPath.row].id) ? .checkmark : .none }
        else { cell.textLabel?.text = "Delete Station"; cell.textLabel?.textColor = .systemRed }
        return cell
    }
    private func edit(_ edit: (inout PodcastStation) -> Void) {
        do { try library.edit { state in guard let index = state.stations.firstIndex(where: { $0.id == id }) else { return }; edit(&state.stations[index]); state.stations[index].updatedAt = Date() }; tableView.reloadData() }
        catch { PodcastUI.showError(error, from: self) }
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 2 {
            do { try library.edit { $0.stations.removeAll { $0.id == id }; $0.deletedStations[id] = Date() }; navigationController?.popToRootViewController(animated: true) } catch { PodcastUI.showError(error, from: self) }; return
        }
        if indexPath.section == 1 {
            let show = shows[indexPath.row]
            edit { $0.allShows = false; if $0.showIDs.contains(show.id) { $0.showIDs.removeAll { $0 == show.id } } else { $0.showIDs.append(show.id) } }; return
        }
        switch indexPath.row {
        case 0:
            let alert = UIAlertController(title: "Station Name", message: nil, preferredStyle: .alert); alert.addTextField { $0.text = self.station?.name }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in if let name = alert?.textFields?.first?.text, !name.trimmingCharacters(in: .whitespaces).isEmpty { self?.edit { $0.name = name } } }); present(alert, animated: true)
        case 1: edit { $0.allShows.toggle() }
        case 2: edit { $0.unplayedOnly.toggle() }
        case 3: edit { $0.newestFirst.toggle() }
        default:
            let alert = UIAlertController(title: indexPath.row == 4 ? "Episodes per Show" : "Media", message: nil, preferredStyle: .actionSheet)
            if indexPath.row == 4 { for number in [0, 1, 2, 3, 5, 10] { alert.addAction(UIAlertAction(title: number == 0 ? "All" : "\(number)", style: .default) { [weak self] _ in self?.edit { $0.episodesPerShow = number } }) } }
            else { for media in ["all", "audio", "video"] { alert.addAction(UIAlertAction(title: media.capitalized, style: .default) { [weak self] _ in self?.edit { $0.media = media } }) } }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel)); alert.popoverPresentationController?.sourceView = tableView.cellForRow(at: indexPath); present(alert, animated: true)
        }
    }
}
