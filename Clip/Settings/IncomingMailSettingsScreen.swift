//
//  IncomingMailSettingsScreen.swift
//  Clip
//

import UIKit

/// Settings for importing incoming emails into the reading list: an on/off
/// toggle and the list of allowed sender addresses. Uses the send-to-Kindle
/// Gmail account + app password.
final class IncomingMailSettingsScreen: UITableViewController {

    private enum Section: Int, CaseIterable { case toggle, senders }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Import from Email"
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .toggle: return 1
        case .senders: return IncomingMailSettings.allowedSenders.count + 1 // +1 = Add row
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section) == .senders ? "Allowed Senders" : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .toggle:
            let account = KindleSendSettings.smtpUsername
            let base = "When on, Click checks \(account.isEmpty ? "your email account" : account) on launch and turns the first link in any new email from an allowed sender into a reading-list item. Uses the same Gmail account and app password as Send to Kindle."
            return account.isEmpty
                ? base + "\n\n⚠️ Set up the email account in Send to Kindle first."
                : base
        case .senders:
            return "Only emails from these addresses are imported."
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
        case .toggle:
            content.text = "Import from Email"
            cell.accessoryView = makeToggle(
                isOn: IncomingMailSettings.isEnabled, action: #selector(toggled(_:)))
        case .senders:
            if indexPath.row < IncomingMailSettings.allowedSenders.count {
                content.text = IncomingMailSettings.allowedSenders[indexPath.row]
            } else {
                content.text = "Add Sender…"
                content.textProperties.color = view.tintColor ?? .systemBlue
                cell.selectionStyle = .default
            }
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .senders,
              indexPath.row == IncomingMailSettings.allowedSenders.count else { return }
        promptForSender()
    }

    override func tableView(
        _ tableView: UITableView, canEditRowAt indexPath: IndexPath
    ) -> Bool {
        Section(rawValue: indexPath.section) == .senders
            && indexPath.row < IncomingMailSettings.allowedSenders.count
    }

    override func tableView(
        _ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete else { return }
        IncomingMailSettings.removeSender(at: indexPath.row)
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }

    @objc private func toggled(_ toggle: UISwitch) {
        IncomingMailSettings.isEnabled = toggle.isOn
        if toggle.isOn {
            Task { await IncomingMailImporter.shared.importNewMail() }
        }
    }

    private func promptForSender() {
        let alert = UIAlertController(
            title: "Add Sender", message: "Emails from this address will be imported.",
            preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "name@example.com"
            field.keyboardType = .emailAddress
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text else { return }
            IncomingMailSettings.addSender(text)
            self?.tableView.reloadData()
        })
        present(alert, animated: true)
    }
}
