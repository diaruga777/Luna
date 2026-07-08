//
//  DoubleSaveRecipientsScreen.swift
//  Luna
//

import LunaDesignSystem
import LunaReadingListUI
import LunaSocial
import LunaStorage
import UIKit

/// Recipient picker for the "Send to Friend" double-save action: either
/// "Ask Every Time" (a double save opens the friend selector in the app) or a
/// preset multi-selection of friends the article is emailed to immediately.
final class DoubleSaveRecipientsScreen: NavHeaderTableController {

    private enum Section: Int, CaseIterable { case askEveryTime, friends }

    private let store = DoubleSaveActionStore.shared
    private let surface = AppSurfaceConfig.current.storageIdentifier
    private var friends: [Friend] = []

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = "Recipients"
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        friends = FriendsStore.shared.items()
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Section(rawValue: section) == .askEveryTime ? 1 : max(friends.count, 0)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section) == .friends && !friends.isEmpty ? "Send To" : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .askEveryTime:
            return "A double save opens Luna's friend selector so you pick recipients each time."
        case .friends:
            return friends.isEmpty
                ? "Add friends on the Friends screen to preset recipients here."
                : "A double save emails the article to every selected friend immediately."
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.selectionStyle = .default

        let mode = store.friendMode(forSurface: surface)
        let presetEmails = store.presetFriendEmails(forSurface: surface)
        switch Section(rawValue: indexPath.section)! {
        case .askEveryTime:
            content.text = DoubleSaveFriendMode.askEveryTime.displayName
            cell.accessoryType = mode == .askEveryTime ? .checkmark : .none
        case .friends:
            let friend = friends[indexPath.row]
            content.text = friend.displayName
            content.secondaryText = friend.email
            cell.accessoryType = mode == .preset && presetEmails.contains(friend.email)
                ? .checkmark : .none
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .askEveryTime:
            store.setFriendMode(.askEveryTime, forSurface: surface)
            store.setPresetFriendEmails([], forSurface: surface)
        case .friends:
            let email = friends[indexPath.row].email
            var emails = store.friendMode(forSurface: surface) == .preset
                ? store.presetFriendEmails(forSurface: surface) : []
            if let index = emails.firstIndex(of: email) {
                emails.remove(at: index)
            } else {
                emails.append(email)
            }
            store.setPresetFriendEmails(emails, forSurface: surface)
            store.setFriendMode(emails.isEmpty ? .askEveryTime : .preset, forSurface: surface)
        }
        tableView.reloadData()
    }
}
