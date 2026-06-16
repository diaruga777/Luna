//
//  ExperimentalSettingsScreen.swift
//  Clip
//

import UIKit

/// Experimental features, off by default: on-device semantic sharing
/// suggestions, and YouTube integration (sign-in, playlist, auto-add).
final class ExperimentalSettingsScreen: UITableViewController {

    private enum Section: Int, CaseIterable { case semantic, youtube }
    private enum YouTubeRow: Int, CaseIterable { case signIn, playlist, autoAdd }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Experimental"
        navigationItem.largeTitleDisplayMode = .never
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .semantic: return 1
        case .youtube: return YouTubeRow.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .semantic: return "Semantic Sharing Suggestions"
        case .youtube: return "YouTube"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .semantic:
            return "Suggests sharing a newly saved article with a friend when it's similar to things you've shared with them before. Off by default."
        case .youtube:
            return "Sign in to find videos by channel and add saved videos to a playlist. Auto-added videos are marked read."
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .semantic:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = "Suggest by Content Similarity"
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            cell.accessoryView = makeToggle(
                isOn: SemanticSharingSettings.isEnabled, action: #selector(semanticToggled(_:)))
            return cell
        case .youtube:
            return youTubeCell(for: YouTubeRow(rawValue: indexPath.row)!)
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .youtube else { return }
        switch YouTubeRow(rawValue: indexPath.row)! {
        case .signIn: signInTapped()
        case .playlist: choosePlaylistTapped()
        case .autoAdd: break
        }
    }

    @objc private func semanticToggled(_ sender: UISwitch) {
        SemanticSharingSettings.isEnabled = sender.isOn
        if sender.isOn { SemanticIndexer.shared.scheduleRun() }
    }

    // MARK: - YouTube

    private func youTubeCell(for row: YouTubeRow) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        switch row {
        case .signIn:
            if GoogleAuthClient.shared.isSignedIn {
                content.text = "Sign Out of YouTube"
                content.textProperties.color = .systemRed
                content.image = UIImage(systemName: "person.crop.circle.badge.checkmark")
            } else {
                content.text = "Sign In to YouTube"
                content.textProperties.color = view.tintColor ?? .systemBlue
                content.image = UIImage(systemName: "person.crop.circle")
            }
        case .playlist:
            content.text = "Playlist"
            content.secondaryText = YouTubeSettings.playlistTitle ?? "None selected"
            content.secondaryTextProperties.color = .secondaryLabel
            content.image = UIImage(systemName: "text.badge.plus")
        case .autoAdd:
            content.text = "Auto-Add Saved Videos"
            cell.accessoryView = makeToggle(
                isOn: YouTubeSettings.autoAddToPlaylist, action: #selector(autoAddToggled(_:)))
            cell.selectionStyle = .none
        }
        cell.contentConfiguration = content
        return cell
    }

    @objc private func autoAddToggled(_ toggle: UISwitch) {
        YouTubeSettings.autoAddToPlaylist = toggle.isOn
    }

    private func signInTapped() {
        if GoogleAuthClient.shared.isSignedIn {
            GoogleAuthClient.shared.signOut()
            tableView.reloadData()
            return
        }
        Task { [weak self] in
            do {
                try await GoogleAuthClient.shared.signIn()
                self?.tableView.reloadData()
            } catch {
                self?.presentInfoAlert(title: "Sign-In Failed", message: "\(error)")
            }
        }
    }

    private func choosePlaylistTapped() {
        guard GoogleAuthClient.shared.isSignedIn else {
            presentInfoAlert(title: "Sign In First", message: "Sign in to YouTube to pick a playlist.")
            return
        }
        Task { [weak self] in
            do {
                let playlists = try await YouTubeAPIClient().listMyPlaylists()
                self?.presentPlaylistSheet(playlists)
            } catch {
                self?.presentInfoAlert(title: "Couldn't Load Playlists", message: "\(error)")
            }
        }
    }

    @MainActor
    private func presentPlaylistSheet(_ playlists: [YouTubePlaylist]) {
        let sheet = UIAlertController(title: "Add Videos To", message: nil, preferredStyle: .actionSheet)
        for playlist in playlists {
            sheet.addAction(UIAlertAction(title: playlist.title, style: .default) { [weak self] _ in
                YouTubeSettings.playlistID = playlist.id
                YouTubeSettings.playlistTitle = playlist.title
                self?.tableView.reloadData()
            })
        }
        sheet.addAction(UIAlertAction(title: "Create \"Watch Later (Click)\"", style: .default) { [weak self] _ in
            Task {
                do {
                    let created = try await YouTubeAPIClient().createPlaylist(title: "Watch Later (Click)")
                    YouTubeSettings.playlistID = created.id
                    YouTubeSettings.playlistTitle = created.title
                    self?.tableView.reloadData()
                } catch {
                    self?.presentInfoAlert(title: "Couldn't Create Playlist", message: "\(error)")
                }
            }
        })
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }
}
