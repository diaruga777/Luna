//
//  EmailAndKindleSettingsScreen.swift
//  Luna
//

import LunaReadingListUI
import LunaReadingList
import LunaMail
import LunaMailAccount
import LunaSend
import LunaSocial
import LunaStorage
import LunaDesignSystem
import UIKit

/// Email & Sending settings. Includes the Reader-only Double Save action
/// (send to Kindle / friend when the same link is saved twice with the Action
/// Button — see `claudedocs/double-save.md`).
final class EmailAndKindleSettingsScreen: NavHeaderTableController {

    private enum Section: Int, CaseIterable {
        case lunaAccount, kindle, doubleSave, importMail, subjectFilters
    }

    /// The double-save action only fires for Reader's Action Button saves, so
    /// its section only shows there.
    private var visibleSections: [Section] {
        Section.allCases.filter { $0 != .doubleSave || AppSurfaceConfig.current == .reader }
    }

    private var doubleSaveSurface: String { AppSurfaceConfig.current.storageIdentifier }

    /// Field tags for the text fields.
    private enum Field: Int { case kindleAddress = 1 }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = "Email & Sending"
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Refresh value rows edited on pushed subscreens (double-save recipients).
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { visibleSections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch visibleSections[section] {
        case .lunaAccount: return EmailAccountStore.shared.isConfigured ? 3 : 1
        case .kindle: return 3 /* mode, kindle address, test send */
        case .doubleSave:
            let showsRecipients = DoubleSaveActionStore.shared
                .action(forSurface: doubleSaveSurface) == .sendToFriend
            return showsRecipients ? 3 : 2 /* kindle choice, friend choice, [recipients] */
        case .importMail: return 2 /* enabled, auto-send */ + IncomingMailSettings.allowedSenders.count + 1 /* add */
        case .subjectFilters: return IncomingMailSettings.subjectFilters.count + 1 /* add */
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch visibleSections[section] {
        case .lunaAccount: return "Sharing Account"
        case .kindle: return "Send to Kindle"
        case .doubleSave: return "Double Save"
        case .importMail: return "Import from Email"
        case .subjectFilters: return "Subject Filters"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch visibleSections[section] {
        case .lunaAccount:
            return "Connect any email provider (Gmail, iCloud, Yahoo, Outlook, or a custom IMAP server) to send articles to contacts and import shares sent to you."
        case .kindle:
            return "Articles are emailed from the connected Luna email account (the section at the top of this screen). That address must be on Amazon's approved-sender list (amazon.com → Preferences → Personal Document Settings), and sending requires the account to be connected."
        case .doubleSave:
            return "Saving the same link twice within 7 seconds with the Action Button shortcut runs this action on the already-saved article."
        case .importMail:
            return "New email from matching senders becomes a reading-list item, optionally forwarding to Kindle automatically overnight."
        case .subjectFilters:
            return "Also import any email whose subject contains one of these phrases, regardless of sender."
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = cell.defaultContentConfiguration()
        cell.accessoryView = nil
        cell.accessoryType = .none
        cell.selectionStyle = .none

        switch visibleSections[indexPath.section] {
        case .lunaAccount:
            if EmailAccountStore.shared.isConfigured {
                switch indexPath.row {
                case 0:
                    content.text = EmailAccountStore.shared.account?.address
                    content.secondaryText = EmailAccountStore.shared.account?.provider.displayName
                case 1:
                    content.text = "Inbox Filter"
                    content.secondaryText = "Keep Luna mail out of your inbox"
                    cell.accessoryType = .disclosureIndicator
                    cell.selectionStyle = .default
                default:
                    content.text = "Sign Out"
                    content.textProperties.color = .systemRed
                    cell.selectionStyle = .default
                }
            } else {
                content.text = "Connect Email Account…"
                content.textProperties.color = view.tintColor ?? .systemBlue
                cell.selectionStyle = .default
            }

        case .kindle:
            switch indexPath.row {
            case 0:
                content.text = "Kindle forwarding settings"
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            case 1:
                return fieldCell("Kindle", placeholder: "name@kindle.com",
                                 text: KindleSendSettings.kindleAddress, field: .kindleAddress)
            default:
                content.text = "Send Test to Kindle"
                content.textProperties.color = view.tintColor ?? .systemBlue
                content.image = UIImage(systemName: "paperplane")
                cell.selectionStyle = .default
            }

        case .doubleSave:
            let action = DoubleSaveActionStore.shared.action(forSurface: doubleSaveSurface)
            switch indexPath.row {
            case 0, 1:
                let rowAction: DoubleSaveAction = indexPath.row == 0 ? .sendToKindle : .sendToFriend
                content.text = rowAction.displayName
                cell.accessoryType = action == rowAction ? .checkmark : .none
                cell.selectionStyle = .default
            default:
                content.text = "Recipients"
                content.secondaryText = doubleSaveRecipientsSummary()
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            }

        case .importMail:
            switch indexPath.row {
            case 0:
                content.text = "Import from Email"
                cell.accessoryView = makeToggle(
                    isOn: IncomingMailSettings.isEnabled, action: #selector(importToggled(_:)))
            case 1:
                content.text = "Also Send to Kindle"
                cell.accessoryView = makeToggle(
                    isOn: IncomingMailSettings.autoSendToKindle, action: #selector(autoSendToggled(_:)))
            default:
                let senderIndex = indexPath.row - 2
                if senderIndex < IncomingMailSettings.allowedSenders.count {
                    content.text = IncomingMailSettings.allowedSenders[senderIndex]
                } else {
                    content.text = "Add Sender…"
                    content.textProperties.color = view.tintColor ?? .systemBlue
                    cell.selectionStyle = .default
                }
            }

        case .subjectFilters:
            if indexPath.row < IncomingMailSettings.subjectFilters.count {
                content.text = IncomingMailSettings.subjectFilters[indexPath.row]
            } else {
                content.text = "Add Subject Filter…"
                content.textProperties.color = view.tintColor ?? .systemBlue
                cell.selectionStyle = .default
            }
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch visibleSections[indexPath.section] {
        case .lunaAccount:
            if EmailAccountStore.shared.isConfigured {
                switch indexPath.row {
                case 1: presentFilterGuide()
                case 2:
                    EmailAccountStore.shared.clear()
                    tableView.reloadData()
                default: break
                }
            } else {
                EmailLoginFlow.present(from: self) { [weak self] _ in self?.tableView.reloadData() }
            }
        case .doubleSave where indexPath.row <= 1:
            DoubleSaveActionStore.shared.setAction(
                indexPath.row == 0 ? .sendToKindle : .sendToFriend,
                forSurface: doubleSaveSurface)
            tableView.reloadSections(IndexSet(integer: indexPath.section), with: .automatic)
        case .doubleSave:
            navigationController?.pushViewController(DoubleSaveRecipientsScreen(), animated: true)
        case .kindle where indexPath.row == 0:
            navigationController?.pushViewController(
                AutoSendBySourceScreen(
                    destinationID: ArticleDestinationID.kindle, destinationName: "Kindle"),
                animated: true)
        case .kindle where indexPath.row == 2:
            sendTestEmail()
        case .importMail where indexPath.row - 2 == IncomingMailSettings.allowedSenders.count:
            promptForSender()
        case .subjectFilters where indexPath.row == IncomingMailSettings.subjectFilters.count:
            promptForSubjectFilter()
        default:
            break
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        switch visibleSections[indexPath.section] {
        case .importMail:
            return indexPath.row >= 2
                && indexPath.row - 2 < IncomingMailSettings.allowedSenders.count
        case .subjectFilters:
            return indexPath.row < IncomingMailSettings.subjectFilters.count
        default:
            return false
        }
    }

    override func tableView(
        _ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        guard editingStyle == .delete else { return }
        switch visibleSections[indexPath.section] {
        case .importMail:
            IncomingMailSettings.removeSender(at: indexPath.row - 2)
        case .subjectFilters:
            IncomingMailSettings.removeSubjectFilter(at: indexPath.row)
        default:
            return
        }
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }

    /// The Recipients row's value text: the chosen friends (by display name),
    /// or the ask-every-time mode.
    private func doubleSaveRecipientsSummary() -> String {
        let store = DoubleSaveActionStore.shared
        guard store.friendMode(forSurface: doubleSaveSurface) == .preset else {
            return "Ask Every Time"
        }
        let emails = store.presetFriendEmails(forSurface: doubleSaveSurface)
        guard !emails.isEmpty else { return "Ask Every Time" }
        let names = emails.map { email in
            FriendsStore.shared.friend(withEmail: email)?.displayName ?? Friend.localPart(email)
        }
        return names.count <= 2 ? names.joined(separator: ", ") : "\(names.count) Contacts"
    }

    // MARK: - Field cells

    private func fieldCell(
        _ label: String, placeholder: String, text: String, field: Field, secure: Bool = false
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
        case nil: break
        }
    }

    // MARK: - Import & filters

    @objc private func importToggled(_ toggle: UISwitch) {
        IncomingMailSettings.isEnabled = toggle.isOn
        if toggle.isOn { Task { await IncomingMailImporter.shared.importNewMail() } }
    }

    @objc private func autoSendToggled(_ toggle: UISwitch) {
        IncomingMailSettings.autoSendToKindle = toggle.isOn
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

    private func promptForSubjectFilter() {
        let alert = UIAlertController(
            title: "Add Subject Filter",
            message: "Email whose subject contains this phrase will be imported, regardless of sender.",
            preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Subject contains…"
            field.autocapitalizationType = .sentences
            field.autocorrectionType = .default
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text else { return }
            IncomingMailSettings.addSubjectFilter(text)
            self?.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    private func presentFilterGuide() {
        guard let providerID = EmailAccountStore.shared.account?.providerID else { return }
        if FilterGuide.isAutomatic(providerID) {
            presentInfoAlert(
                title: "Filter Active",
                message: "Luna set up an inbox rule automatically for this account.")
            return
        }
        let alert = UIAlertController(
            title: "Inbox Filter", message: FilterGuide.instructions(for: providerID),
            preferredStyle: .alert)
        if let url = FilterGuide.settingsURL(for: providerID) {
            alert.addAction(UIAlertAction(title: "Open Filter Settings", style: .default) { _ in
                UIApplication.shared.open(url)
            })
        }
        alert.addAction(UIAlertAction(title: "Done", style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Test sends

    private func sendTestEmail() {
        guard ArticleSendCoordinator.shared.isConfigured(destinationID: ArticleDestinationID.kindle) else {
            presentInfoAlert(title: "Not Configured",
                             message: "Connect an email account and enter your Kindle address first.")
            return
        }
        Task { [weak self] in
            do {
                try await ArticleSendCoordinator.shared.sendTestDocument(
                    toDestinationID: ArticleDestinationID.kindle)
                self?.presentInfoAlert(
                    title: "Test Sent",
                    message: "Check your Kindle library in a few minutes. If nothing arrives, confirm the sender is on Amazon's approved list.")
            } catch {
                self?.presentInfoAlert(title: "Test Failed", message: "\(error)")
            }
        }
    }

}
