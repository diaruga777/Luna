import UIKit
import LunaMusicCore

@MainActor
public enum MusicSettings {
    public static var connectionController: (() -> UIViewController)?
    public static var connectionError: String?
}

@MainActor
public final class MusicSettingsViewController: UITableViewController {
    private let vault = VaultMusicController.shared
    private var cached: [MusicSong] = []
    private var observer: NSObjectProtocol?
    public init() { super.init(style: .insetGrouped); title = "Settings" }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    public override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "row")
        observer = NotificationCenter.default.addObserver(forName: .lunaMusicVaultChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        reload()
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    private func reload() { cached = vault.cachedSongs; tableView.reloadData() }
    public override func numberOfSections(in tableView: UITableView) -> Int { 3 }
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 2 : section == 1 ? 2 : cached.count
    }
    public override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        ["Music Sources", "Automatic Downloads", "Cached Songs (\(cached.count))"][section]
    }
    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 { return MusicSettings.connectionError ?? vault.errorMessage ?? "Put files in Music/Artist/Album inside your Mac’s Vault folder. New songs appear when the library refreshes." }
        if section == 1 { return vault.cacheProgress ?? "Keep songs from your most-played Vault playlists on this iPhone. Manually downloaded songs stay cached. Set 0 to disable automatic downloads." }
        let bytes = cached.reduce(Int64(0)) { $0 + ($1.file?.size ?? 0) }
        return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) on this iPhone. Swipe a song to remove its cache. The original stays on your Mac. Removed songs won’t download automatically again unless you choose Download."
    }
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "row", for: indexPath)
        cell.accessoryView = nil; cell.accessoryType = .none; cell.selectionStyle = .default
        var config = cell.defaultContentConfiguration()
        switch indexPath.section {
        case 0:
            config.text = indexPath.row == 0 ? "Luna Mac" : "Apple Music Access"
            config.image = UIImage(systemName: indexPath.row == 0 ? "desktopcomputer" : "music.note")
            cell.accessoryType = .disclosureIndicator
        case 1:
            if indexPath.row == 0 {
                config.text = "Top \(vault.state.automaticPlaylistCount) playlists"
                let stepper = UIStepper(); stepper.minimumValue = 0; stepper.maximumValue = 10
                stepper.value = Double(vault.state.automaticPlaylistCount)
                stepper.accessibilityLabel = "Automatically cached playlists"
                stepper.accessibilityValue = String(vault.state.automaticPlaylistCount)
                stepper.addAction(UIAction { [weak self, weak stepper] _ in
                    guard let self, let stepper else { return }
                    MusicStyle.run(from: self, errorTitle: "Couldn’t Save Setting") { try self.vault.setAutomaticPlaylistCount(Int(stepper.value)) }
                }, for: .valueChanged)
                cell.accessoryView = stepper; cell.selectionStyle = .none
            } else { config.text = "Retry Downloads"; config.image = UIImage(systemName: "arrow.down.circle") }
        default:
            let song = cached[indexPath.row]
            config.text = song.title; config.secondaryText = song.artist
            config.image = MusicStyle.image(song, size: 64) ?? UIImage(systemName: "music.note")
            config.imageProperties.maximumSize = CGSize(width: 44, height: 44)
        }
        cell.contentConfiguration = config; return cell
    }
    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0, indexPath.row == 0, let controller = MusicSettings.connectionController?() {
            navigationController?.pushViewController(controller, animated: true)
        } else if indexPath.section == 0, indexPath.row == 1, let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        else if indexPath.section == 1, indexPath.row == 1 { vault.retryDownloads() }
    }
    public override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 2 else { return nil }
        let song = cached[indexPath.row]
        let action = UIContextualAction(style: .destructive, title: "Remove Cache") { [weak self] _, _, done in
            guard let self else { done(false); return }
            MusicStyle.run(from: self, errorTitle: "Couldn’t Remove Cache") { try await self.vault.removeCachedSong(song); done(true) }
        }
        return UISwipeActionsConfiguration(actions: [action])
    }
}
