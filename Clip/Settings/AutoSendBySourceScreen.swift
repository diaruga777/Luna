//
//  AutoSendBySourceScreen.swift
//  Clip
//

import UIKit

/// Per-capture-source auto-send configuration for one ereader destination
/// (Kindle or Boox). Lets the user choose which sources auto-send: App Intents
/// (Shortcuts) and in-app saves via the send mode, plus on/off for email, the
/// share sheet & paste, and friend shares (with per-friend overrides).
final class AutoSendBySourceScreen: UITableViewController {

    private enum Section: Int, CaseIterable { case sources, friends }
    private enum SourceRow: Int, CaseIterable { case appIntents, email, shareAndPaste, friendShares }

    private let destinationID: String
    private let destinationName: String
    private var friends: [Friend] = []

    init(destinationID: String, destinationName: String) {
        self.destinationID = destinationID
        self.destinationName = destinationName
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Forwarding Settings"
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        friends = FriendsStore.shared.items()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        friends.isEmpty ? 1 : Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .sources: return SourceRow.allCases.count
        case .friends: return friends.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .sources: return "Forwarding settings: \(destinationName)"
        case .friends: return "Always forward to..."
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .sources:
            return "Choose which saves \(destinationName) receives automatically.\n\nWith \"Double Save\", saving twice in rapid successtion forwards. (e.g. 2 Action Button presses). "
        case .friends:
            return "Override forwarding settings per friend. Friends not listed here use the default setting above."
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryView = nil
        cell.selectionStyle = .none

        switch Section(rawValue: indexPath.section)! {
        case .sources:
            configureSourceRow(SourceRow(rawValue: indexPath.row)!, content: &content, cell: cell)
        case .friends:
            let username = friends[indexPath.row].card.username
            content.text = username
            cell.accessoryView = makeToggle(
                isOn: SourceSendSettings.friendShareEnabled(
                    forDestination: destinationID, username: username)
            ) { [weak self] isOn in
                guard let self else { return }
                SourceSendSettings.setFriendShareEnabled(
                    isOn, forDestination: self.destinationID, username: username)
            }
        }
        cell.contentConfiguration = content
        return cell
    }

    private func configureSourceRow(
        _ row: SourceRow,
        content: inout UIListContentConfiguration,
        cell: UITableViewCell
    ) {
        switch row {
        case .appIntents:
            content.text = CaptureSource.appIntent.displayName
            cell.accessoryView = makeModeButton()
        case .email:
            content.text = CaptureSource.email.displayName
            cell.accessoryView = makeToggle(
                isOn: SourceSendSettings.emailEnabled(forDestination: destinationID)
            ) { [weak self] isOn in
                guard let self else { return }
                SourceSendSettings.setEmailEnabled(isOn, forDestination: self.destinationID)
            }
        case .shareAndPaste:
            content.text = "Share Sheet & Paste"
            cell.accessoryView = makeToggle(
                isOn: SourceSendSettings.shareAndPasteEnabled(forDestination: destinationID)
            ) { [weak self] isOn in
                guard let self else { return }
                SourceSendSettings.setShareAndPasteEnabled(isOn, forDestination: self.destinationID)
            }
        case .friendShares:
            content.text = CaptureSource.friendShare.displayName
            cell.accessoryView = makeToggle(
                isOn: SourceSendSettings.friendSharesEnabledDefault(forDestination: destinationID)
            ) { [weak self] isOn in
                guard let self else { return }
                SourceSendSettings.setFriendSharesEnabledDefault(
                    isOn, forDestination: self.destinationID)
            }
        }
    }

    private func makeToggle(isOn: Bool, onChange: @escaping (Bool) -> Void) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addAction(UIAction { [weak toggle] _ in onChange(toggle?.isOn ?? false) }, for: .valueChanged)
        return toggle
    }

    private func makeModeButton() -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = true
        let current = SourceSendSettings.appIntentsMode(forDestination: destinationID)
        button.menu = UIMenu(children: ArticleSendMode.allCases.map { mode in
            UIAction(title: mode.displayName, state: mode == current ? .on : .off) { [weak self] _ in
                guard let self else { return }
                SourceSendSettings.setAppIntentsMode(mode, forDestination: self.destinationID)
                self.tableView.reloadData()
            }
        })
        button.sizeToFit()
        return button
    }
}
