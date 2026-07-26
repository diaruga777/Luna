//
//  FriendsViewController.swift
//  LunaSocialUI
//

import LunaSocial
import LunaDesignSystem
import ContactsUI
import UIKit
import LunaModels

/// The Contacts screen (shared by all three apps): the saved email recipients,
/// an entry to the pending-requests moderation queue (badged), and ways to add
/// a contact by email or from the system Contacts picker.
public final class FriendsViewController: NavHeaderTableController, CNContactPickerDelegate {

    private var contacts: [Friend] = FriendsStore.shared.activeItems()
    private var blocked: [Friend] = FriendsStore.shared.blockedItems()
    private var pendingCount = PendingRequestsStore.shared.count

    private enum Section: Int, CaseIterable { case pending, add, contacts, blocked }

    public init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        headerTitle = L10n.string("Contacts")
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
        contacts = FriendsStore.shared.activeItems()
        blocked = FriendsStore.shared.blockedItems()
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
        case .contacts: return contacts.count
        case .blocked: return blocked.count
        }
    }

    public override func tableView(
        _ tableView: UITableView, titleForHeaderInSection section: Int
    ) -> String? {
        switch Section(rawValue: section)! {
        case .contacts: return contacts.isEmpty ? nil : L10n.string("Contacts")
        case .blocked: return blocked.isEmpty ? nil : L10n.string("Blocked")
        default: return nil
        }
    }

    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var config = cell.defaultContentConfiguration()
        cell.accessoryType = .disclosureIndicator
        switch Section(rawValue: indexPath.section)! {
        case .pending:
            config.text = L10n.string("Pending Requests")
            config.secondaryText = "\(pendingCount) waiting"
            config.image = UIImage(systemName: "tray.and.arrow.down")
        case .add:
            if indexPath.row == 0 {
                config.text = L10n.string("Add by Email")
                config.image = UIImage(systemName: "envelope")
            } else {
                config.text = L10n.string("Add from Phone Contacts")
                config.image = UIImage(systemName: "person.crop.circle.badge.plus")
            }
            cell.accessoryType = .none
        case .contacts, .blocked:
            let contact = Section(rawValue: indexPath.section) == .contacts
                ? contacts[indexPath.row] : blocked[indexPath.row]
            config.text = contact.displayName
            config.secondaryText = contact.email
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
        case .contacts, .blocked:
            let friend = Section(rawValue: indexPath.section) == .contacts
                ? contacts[indexPath.row] : blocked[indexPath.row]
            navigationController?.pushViewController(
                FriendDetailViewController(friend: friend), animated: true)
        }
    }

    public override func tableView(
        _ tableView: UITableView, canEditRowAt indexPath: IndexPath
    ) -> Bool {
        let section = Section(rawValue: indexPath.section)
        return section == .contacts || section == .blocked
    }

    public override func tableView(
        _ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete else { return }
        let contact: Friend
        switch Section(rawValue: indexPath.section)! {
        case .contacts: contact = contacts[indexPath.row]
        case .blocked: contact = blocked[indexPath.row]
        default: return
        }
        FriendsStore.shared.remove(email: contact.email)
        reload()
    }

    // MARK: - Adding

    private func promptForEmail() {
        EmailRecipientPrompt.presentEmailAlert(from: self, title: L10n.string("Add contact")) { [weak self] raw in
            guard Friend.isValidEmail(raw) else { return }
            _ = FriendsStore.shared.add(email: raw)
            self?.reload()
        }
    }

    private func presentContactPicker() {
        present(EmailRecipientPrompt.makeContactPicker(delegate: self), animated: true)
    }

    public func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
        guard let email = contact.emailAddresses.first?.value as String?,
              Friend.isValidEmail(email) else { return }
        let name = CNContactFormatter.string(from: contact, style: .fullName)
        _ = FriendsStore.shared.add(email: email, name: name)
        reload()
    }
}
