//
//  FriendDetailViewController.swift
//  LunaSocialUI
//

import LunaSocial
import LunaDesignSystem
import UIKit
import LunaModels

/// Per-contact settings: rename, notifications, block/unblock, and remove.
public final class FriendDetailViewController: NavHeaderTableController {

    private var friend: Friend

    private enum Section: Int, CaseIterable { case profile, notifications, blocking, remove }

    public init(friend: Friend) {
        self.friend = friend
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        headerTitle = friend.displayName
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    public override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Section(rawValue: section) == .notifications && friend.isBlocked ? 0 : 1
    }

    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var config = cell.defaultContentConfiguration()
        cell.accessoryType = .none
        cell.accessoryView = nil
        switch Section(rawValue: indexPath.section)! {
        case .profile:
            config.text = friend.name ?? L10n.string("Set a name")
            config.secondaryText = friend.email
            cell.accessoryType = .disclosureIndicator
        case .notifications:
            config.text = L10n.string("Notify on every share")
            let toggle = UISwitch()
            toggle.isOn = friend.notifyOnEveryShare
            toggle.addTarget(self, action: #selector(toggleNotify(_:)), for: .valueChanged)
            cell.accessoryView = toggle
        case .blocking:
            config.text = friend.isBlocked ? L10n.string("Unblock Contact") : L10n.string("Block Contact")
            config.textProperties.color = friend.isBlocked ? .systemBlue : .systemRed
        case .remove:
            config.text = L10n.string("Remove Contact")
            config.textProperties.color = .systemRed
        }
        cell.contentConfiguration = config
        return cell
    }

    public override func tableView(
        _ tableView: UITableView, titleForFooterInSection section: Int
    ) -> String? {
        Section(rawValue: section) == .notifications
            ? L10n.string("By default you're notified only the first time this contact shares with you.")
            : nil
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .profile: promptRename()
        case .notifications: break
        case .blocking:
            FriendsStore.shared.setBlocked(!friend.isBlocked, email: friend.email)
            navigationController?.popViewController(animated: true)
        case .remove:
            FriendsStore.shared.remove(email: friend.email)
            navigationController?.popViewController(animated: true)
        }
    }

    @objc private func toggleNotify(_ toggle: UISwitch) {
        friend.notifyOnEveryShare = toggle.isOn
        FriendsStore.shared.update(friend)
    }

    private func promptRename() {
        let alert = UIAlertController(title: L10n.string("Name"), message: friend.email, preferredStyle: .alert)
        alert.addTextField { $0.text = self.friend.name; $0.placeholder = L10n.string("Name") }
        alert.addAction(UIAlertAction(title: L10n.string("Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("Save"), style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.friend.name = (name?.isEmpty ?? true) ? nil : name
            FriendsStore.shared.update(self.friend)
            self.headerTitle = self.friend.displayName
            self.tableView.reloadData()
        })
        present(alert, animated: true)
    }
}
