//
//  RecipientPickerViewController.swift
//  LunaSocialUI
//

import LunaSocial
import LunaDesignSystem
import ContactsUI
import UIKit
import LunaModels

/// Picks one or more email recipients: the saved friends list (multi-select),
/// plus "Enter email…" and "Add from Contacts" (the system `CNContactPicker`,
/// which needs no Contacts permission). Returns the chosen addresses.
public final class RecipientPickerViewController: UITableViewController,
    CNContactPickerDelegate {

    private let onComplete: ([String]) -> Void
    private let friends = FriendsStore.shared.activeItems()
    /// Selected emails (lowercased). Ad-hoc entries (typed / from Contacts) are
    /// appended to `extraRecipients` so they render as rows too.
    private var selected = Set<String>()
    private var extraRecipients: [Friend] = []

    private enum Section: Int, CaseIterable { case actions, recipients }

    public init(onComplete: @escaping ([String]) -> Void) {
        self.onComplete = onComplete
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        title = L10n.string("Send to")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        updateSendButton()
    }

    private var allRecipients: [Friend] { extraRecipients + friends }

    // MARK: - Table

    public override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .actions: return 2
        case .recipients: return allRecipients.count
        }
    }

    public override func tableView(
        _ tableView: UITableView, titleForHeaderInSection section: Int
    ) -> String? {
        Section(rawValue: section) == .recipients && !allRecipients.isEmpty
            ? L10n.string("Contacts")
            : nil
    }

    public override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var config = cell.defaultContentConfiguration()
        switch Section(rawValue: indexPath.section)! {
        case .actions:
            if indexPath.row == 0 {
                config.text = L10n.string("Enter email address…")
                config.image = UIImage(systemName: "envelope")
            } else {
                config.text = L10n.string("Add from Phone Contacts")
                config.image = UIImage(systemName: "person.crop.circle.badge.plus")
            }
            cell.accessoryType = .none
        case .recipients:
            let friend = allRecipients[indexPath.row]
            config.text = friend.displayName
            config.secondaryText = friend.email
            cell.accessoryType = selected.contains(friend.email) ? .checkmark : .none
        }
        cell.contentConfiguration = config
        return cell
    }

    public override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .actions:
            indexPath.row == 0 ? promptForEmail() : presentContactPicker()
        case .recipients:
            let email = allRecipients[indexPath.row].email
            if selected.contains(email) { selected.remove(email) } else { selected.insert(email) }
            tableView.reloadRows(at: [indexPath], with: .automatic)
            updateSendButton()
        }
    }

    // MARK: - Adding recipients

    private func promptForEmail() {
        EmailRecipientPrompt.presentEmailAlert(from: self, title: L10n.string("Recipient email")) { [weak self] raw in
            self?.addRecipient(email: raw, name: nil)
        }
    }

    private func addRecipient(email raw: String, name: String?) {
        let email = Friend.normalize(raw)
        guard Friend.isValidEmail(email) else { return }
        selected.insert(email)
        if !allRecipients.contains(where: { $0.email == email }) {
            extraRecipients.insert(Friend(email: email, name: name), at: 0)
        }
        tableView.reloadData()
        updateSendButton()
    }

    private func presentContactPicker() {
        present(EmailRecipientPrompt.makeContactPicker(delegate: self), animated: true)
    }

    public func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
        guard let email = contact.emailAddresses.first?.value as String? else { return }
        let name = CNContactFormatter.string(from: contact, style: .fullName)
        addRecipient(email: email, name: name)
    }

    // MARK: - Send

    private func updateSendButton() {
        let count = selected.count
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: count == 0 ? L10n.string("Send") : L10n.string("Send (\(count))"),
            style: .done, target: self, action: #selector(send))
        navigationItem.rightBarButtonItem?.isEnabled = count > 0
    }

    @objc private func send() {
        dismiss(animated: true) { [onComplete, selected] in onComplete(Array(selected)) }
    }

    @objc private func cancel() { dismiss(animated: true) }
}
