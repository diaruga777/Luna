//
//  SendAndYouTubeSettingsScreens.swift
//  Clip
//

import UIKit

// MARK: - Send to Kindle

/// Send-to-Kindle configuration: mode, Kindle address, SMTP account, and a
/// test send.
final class KindleSettingsScreen: UITableViewController {

    private enum Row { case mode, kindleAddress, provider, host, username, password, testSend }

    private var rows: [Row] {
        var rows: [Row] = [.mode, .kindleAddress, .provider]
        if KindleSendSettings.provider == .custom { rows.append(.host) }
        rows += [.username, .password, .testSend]
        return rows
    }

    private enum Field: Int { case kindleAddress = 1, host, username, password }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Send to Kindle"
        navigationItem.largeTitleDisplayMode = .never
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        rows.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Articles are emailed as EPUBs from your account. For Gmail, use an app password (myaccount.google.com → Security → App passwords). Amazon only accepts mail from approved senders: add the account email at amazon.com → Manage Your Content and Devices → Preferences → Personal Document Settings. \"Double Save\" sends an article when you save the same page twice within a few seconds."
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()

        switch rows[indexPath.row] {
        case .mode:
            content.text = "Send Articles"
            cell.accessoryView = makeModeButton()
            cell.selectionStyle = .none
        case .kindleAddress:
            return makeFieldCell(label: "Kindle", placeholder: "name@kindle.com",
                                 text: KindleSendSettings.kindleAddress, field: .kindleAddress)
        case .provider:
            content.text = "Email Provider"
            let control = UISegmentedControl(
                items: KindleSendSettings.Provider.allCases.map(\.displayName))
            control.selectedSegmentIndex = KindleSendSettings.Provider.allCases
                .firstIndex(of: KindleSendSettings.provider) ?? 0
            control.addTarget(self, action: #selector(providerChanged(_:)), for: .valueChanged)
            cell.accessoryView = control
            cell.selectionStyle = .none
        case .host:
            return makeFieldCell(label: "Server", placeholder: "smtp.example.com",
                                 text: KindleSendSettings.customHost, field: .host)
        case .username:
            return makeFieldCell(label: "Email", placeholder: "you@gmail.com",
                                 text: KindleSendSettings.smtpUsername, field: .username)
        case .password:
            return makeFieldCell(label: "Password", placeholder: "App password",
                                 text: KeychainSendCredentialsStore.shared.smtpPassword() ?? "",
                                 field: .password, secure: true)
        case .testSend:
            content.text = "Send Test to Kindle"
            content.textProperties.color = view.tintColor ?? .systemBlue
            content.image = UIImage(systemName: "paperplane")
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if case .testSend = rows[indexPath.row] { sendTestEmail() }
    }

    private func makeFieldCell(
        label: String, placeholder: String, text: String, field: Field, secure: Bool = false
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let nameLabel = UILabel()
        nameLabel.text = label
        nameLabel.font = .preferredFont(forTextStyle: .body)

        let textField = UITextField()
        textField.placeholder = placeholder
        textField.text = text
        textField.tag = field.rawValue
        textField.isSecureTextEntry = secure
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.keyboardType = secure ? .default : .emailAddress
        textField.textAlignment = .right
        textField.textColor = .secondaryLabel
        textField.addTarget(self, action: #selector(fieldEdited(_:)), for: .editingChanged)
        textField.addTarget(self, action: #selector(fieldEdited(_:)), for: .editingDidEnd)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(nameLabel)
        cell.contentView.addSubview(textField)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            textField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 12),
            textField.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            textField.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        cell.selectionStyle = .none
        return cell
    }

    @objc private func fieldEdited(_ textField: UITextField) {
        let value = (textField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch Field(rawValue: textField.tag) {
        case .kindleAddress: KindleSendSettings.kindleAddress = value
        case .host: KindleSendSettings.customHost = value
        case .username: KindleSendSettings.smtpUsername = value
        case .password: KeychainSendCredentialsStore.shared.setSMTPPassword(value)
        case nil: break
        }
    }

    private func makeModeButton() -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = true
        button.menu = UIMenu(children: KindleSendSettings.SendMode.allCases.map { mode in
            UIAction(title: mode.displayName,
                     state: mode == KindleSendSettings.sendMode ? .on : .off) { [weak self] _ in
                KindleSendSettings.sendMode = mode
                self?.tableView.reloadData()
            }
        })
        button.sizeToFit()
        return button
    }

    @objc private func providerChanged(_ control: UISegmentedControl) {
        let providers = KindleSendSettings.Provider.allCases
        KindleSendSettings.provider = providers[max(0, min(control.selectedSegmentIndex, providers.count - 1))]
        tableView.reloadData()
    }

    private func sendTestEmail() {
        guard ArticleSendCoordinator.shared.isConfigured else {
            presentInfoAlert(title: "Not Configured",
                             message: "Fill in the Kindle address, email, and app password first.")
            return
        }
        Task { [weak self] in
            do {
                try await ArticleSendCoordinator.shared.sendTestDocument()
                self?.presentInfoAlert(
                    title: "Test Sent",
                    message: "Check your Kindle library in a few minutes. If nothing arrives, confirm the sender is on Amazon's approved list.")
            } catch {
                self?.presentInfoAlert(title: "Test Failed", message: "\(error)")
            }
        }
    }
}

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
