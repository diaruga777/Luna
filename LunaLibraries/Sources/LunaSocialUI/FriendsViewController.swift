//
//  FriendsViewController.swift
//  LunaSocialUI
//

import LunaSocial
import LunaDesignSystem
import ContactsUI
import UIKit

/// The Friends screen (shared by all three apps): the saved email recipients,
/// an entry to the pending-requests moderation queue (badged), and ways to add
/// a friend by email or from the system Contacts picker.
public final class FriendsViewController: NavHeaderTableController, CNContactPickerDelegate {

    private var friends: [Friend] = FriendsStore.shared.items()
    private var pendingCount = PendingRequestsStore.shared.count

    private enum Section: Int, CaseIterable { case pending, add, friends }

    public init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        headerTitle = "Friends"
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload),
            name: .friendsListChanged, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(reload),
            name: .pendingRequestsChanged, object: nil)
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    @objc private func reload() {
        friends = FriendsStore.shared.items()
        pendingCount = PendingRequestsStore.shared.count
        tableView.reloadData()
    }

    // MARK: - Table

    public override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .pending: return pendingCount > 0 ? 1 : 0
        case .add: return 2
        case .friends: return friends.count
        }
    }

    public override func tableView(
        _ tableView: UITableView, titleForHeaderInSection section: Int
    ) -> String? {
        Section(rawValue: section) == .friends && !friends.isEmpty ? "Friends" : nil
    }

    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var config = cell.defaultContentConfiguration()
        cell.accessoryType = .disclosureIndicator
        switch Section(rawValue: indexPath.section)! {
        case .pending:
            config.text = "Pending Requests"
            config.secondaryText = "\(pendingCount) waiting"
            config.image = UIImage(systemName: "tray.and.arrow.down")
        case .add:
            if indexPath.row == 0 {
                config.text = "Add by Email"
                config.image = UIImage(systemName: "envelope")
            } else {
                config.text = "Add from Contacts"
                config.image = UIImage(systemName: "person.crop.circle.badge.plus")
            }
            cell.accessoryType = .none
        case .friends:
            let friend = friends[indexPath.row]
            config.text = friend.displayName
            config.secondaryText = friend.email
        }
        cell.contentConfiguration = config
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .pending:
            navigationController?.pushViewController(PendingRequestsViewController(), animated: true)
        case .add:
            indexPath.row == 0 ? promptForEmail() : presentContactPicker()
        case .friends:
            let friend = friends[indexPath.row]
            navigationController?.pushViewController(
                FriendDetailViewController(friend: friend), animated: true)
        }
    }

    public override func tableView(
        _ tableView: UITableView, canEditRowAt indexPath: IndexPath
    ) -> Bool {
        Section(rawValue: indexPath.section) == .friends
    }

    public override func tableView(
        _ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete, Section(rawValue: indexPath.section) == .friends else { return }
        FriendsStore.shared.remove(email: friends[indexPath.row].email)
        reload()
    }

    // MARK: - Adding

    private func promptForEmail() {
        let alert = UIAlertController(title: "Add friend", message: nil, preferredStyle: .alert)
        alert.addTextField {
            $0.placeholder = "name@example.com"
            $0.keyboardType = .emailAddress
            $0.autocapitalizationType = .none
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard let raw = alert?.textFields?.first?.text, Friend.isValidEmail(raw) else { return }
            _ = FriendsStore.shared.add(email: raw)
            self?.reload()
        })
        present(alert, animated: true)
    }

    private func presentContactPicker() {
        let picker = CNContactPickerViewController()
        picker.predicateForEnablingContact = NSPredicate(format: "emailAddresses.@count > 0")
        picker.displayedPropertyKeys = [CNContactEmailAddressesKey]
        picker.delegate = self
        present(picker, animated: true)
    }

    public func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
        guard let email = contact.emailAddresses.first?.value as String?,
              Friend.isValidEmail(email) else { return }
        let name = CNContactFormatter.string(from: contact, style: .fullName)
        _ = FriendsStore.shared.add(email: email, name: name)
        reload()
    }
}
