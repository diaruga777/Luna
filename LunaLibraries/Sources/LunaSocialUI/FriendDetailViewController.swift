//
//  FriendDetailViewController.swift
//  Luna
//

import LunaSemantic
import LunaSocial
import LunaStorage
import LunaDesignSystem
import UIKit

/// Per-friend settings: auto-send websites, share notifications, and removal.
/// Pushed when a friend row is tapped on the Friends screen.
public final class FriendDetailViewController: NavHeaderTableController {

    private enum Section: Int, CaseIterable {
        case autoSend
        case notifications
        case remove
    }

    private let friend: Friend
    /// Called after the friend is removed so the list can pop back.
    private let onRemoved: () -> Void

    public init(friend: Friend, onRemoved: @escaping () -> Void) {
        self.friend = friend
        self.onRemoved = onRemoved
        super.init(style: .insetGrouped)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        headerTitle = friend.card.username
        super.viewDidLoad()
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The auto-send count may have changed in the sub-page.
        tableView.reloadData()
    }

    public override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .autoSend:
            return "Links you save from these websites are sent to \(friend.card.username) automatically."
        case .notifications:
            return "Get a notification when \(friend.card.username) shares an article with you."
        case .remove:
            return nil
        }
    }

    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()

        switch Section(rawValue: indexPath.section)! {
        case .autoSend:
            content.text = "Auto-Send Websites"
            let count = ShareSuggestionStore.shared
                .alwaysSharedBaseURLs(friendUUID: friend.card.uuid).count
            content.secondaryText = count == 0 ? "Off" : "\(count) site\(count == 1 ? "" : "s")"
            cell.accessoryType = .disclosureIndicator
            cell.contentConfiguration = content

        case .notifications:
            content.text = "Notify When They Share"
            cell.contentConfiguration = content
            let toggle = UISwitch()
            toggle.isOn = FriendNotificationSettings.isNotifyEnabled(friendUUID: friend.card.uuid)
            toggle.addTarget(self, action: #selector(notifyToggled(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            cell.selectionStyle = .none

        case .remove:
            content.text = "Remove Friend"
            content.textProperties.color = .systemRed
            cell.contentConfiguration = content
        }
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .autoSend:
            navigationController?.pushViewController(
                AutoSendWebsitesViewController(friend: friend), animated: true)
        case .notifications:
            break
        case .remove:
            confirmRemove()
        }
    }

    @objc private func notifyToggled(_ toggle: UISwitch) {
        FriendNotificationSettings.setNotify(toggle.isOn, friendUUID: friend.card.uuid)
        if toggle.isOn { NotificationManager.requestAuthorization() }
    }

    private func confirmRemove() {
        let alert = UIAlertController(
            title: "Remove \(friend.card.username)?",
            message: "They'll stay your friend until you remove them on their end too, but you'll stop receiving and auto-sending to them.",
            preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "Remove Friend", style: .destructive) { [weak self] _ in
            guard let self else { return }
            FriendsStore.shared.delete(uuid: self.friend.card.uuid)
            ShareSuggestionStore.shared.wipe(friendUUID: self.friend.card.uuid)
            SemanticIndexStore.shared.removePerson(self.friend.card.uuid)
            FriendNotificationSettings.setNotify(false, friendUUID: self.friend.card.uuid)
            self.onRemoved()
            self.navigationController?.popViewController(animated: true)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceView = view
        present(alert, animated: true)
    }
}

/// The per-friend list of websites (base URLs) to auto-send, each toggleable.
/// Candidates come from the hosts already in the reading list plus any sites
/// already enabled for this friend.
public final class AutoSendWebsitesViewController: UITableViewController {

    private let friend: Friend
    private var baseURLs: [String] = []

    public init(friend: Friend) {
        self.friend = friend
        super.init(style: .insetGrouped)
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = "Auto-Send"
        navigationItem.largeTitleDisplayMode = .never
        loadBaseURLs()
    }

    /// Distinct base URLs from saved articles (documents have none), unioned
    /// with sites already enabled for this friend, sorted.
    private func loadBaseURLs() {
        var hosts = Set<String>()
        for item in ReadingListStore.shared.items()
        where item.urlString.hasPrefix("http") {
            if let base = ShareSuggestionStore.baseURL(of: item.urlString) {
                hosts.insert(base)
            }
        }
        ShareSuggestionStore.shared
            .alwaysSharedBaseURLs(friendUUID: friend.card.uuid)
            .forEach { hosts.insert($0) }
        baseURLs = hosts.sorted()
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(baseURLs.count, 1)
    }

    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        baseURLs.isEmpty
            ? "Save some articles first — the websites you save from show up here to auto-send."
            : "New links from an enabled website are sent to \(friend.card.username) the moment you save them."
    }

    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()

        if baseURLs.isEmpty {
            content.text = "No websites yet"
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        }

        let base = baseURLs[indexPath.row]
        content.text = base
        cell.contentConfiguration = content
        let toggle = UISwitch()
        toggle.isOn = ShareSuggestionStore.shared
            .isAlwaysShared(baseURL: base, friendUUID: friend.card.uuid)
        toggle.tag = indexPath.row
        toggle.addTarget(self, action: #selector(siteToggled(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        cell.selectionStyle = .none
        return cell
    }

    @objc private func siteToggled(_ toggle: UISwitch) {
        guard baseURLs.indices.contains(toggle.tag) else { return }
        ShareSuggestionStore.shared.setAlwaysShare(
            baseURL: baseURLs[toggle.tag],
            friendUUID: friend.card.uuid,
            friendUsername: friend.card.username,
            enabled: toggle.isOn)
    }
}
