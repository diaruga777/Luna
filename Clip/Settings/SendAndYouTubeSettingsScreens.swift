//
//  SendAndYouTubeSettingsScreens.swift
//  Clip
//

import UIKit

// MARK: - YouTube

/// YouTube sign-in, playlist selection, and auto-add toggle.
final class YouTubeSettingsScreen: UITableViewController {
    private enum Row: Int, CaseIterable { case signIn, playlist, autoAdd }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "YouTube"
        navigationItem.largeTitleDisplayMode = .never
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Sign in to find videos by channel and title and to add saved videos to a playlist. The real Watch Later list is closed to apps, so pick or create a playlist instead. Auto-added videos are marked read immediately."
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()

        switch Row(rawValue: indexPath.row)! {
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

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Row(rawValue: indexPath.row)! {
        case .signIn: signInTapped()
        case .playlist: choosePlaylistTapped()
        case .autoAdd: break
        }
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
        sheet.addAction(UIAlertAction(title: "Create \"Watch Later (Clip)\"", style: .default) { [weak self] _ in
            Task {
                do {
                    let created = try await YouTubeAPIClient().createPlaylist(title: "Watch Later (Clip)")
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
