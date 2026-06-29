//
//  EmailAndKindleSettingsScreen.swift
//  Clip
//

import ClipDesignSystem
import ClipReadingListUI
import ClipReadingList
import ClipMail
import ClipSend
import UIKit

/// Combined Email & Kindle settings. One Gmail account (app password) powers
/// both outgoing Send-to-Kindle and incoming email import. Three sections:
/// the shared email account, Send-to-Kindle, and Import-from-Email.
final class EmailAndKindleSettingsScreen: UITableViewController {

    private enum Section: Int, CaseIterable { case account, kindle, importMail, subjectFilters }

    /// Field tags for the text fields.
    private enum Field: Int { case host = 1, username, password, kindleAddress }

    private var accountRows: [Field] {
        var rows: [Field] = []
        if KindleSendSettings.provider == .custom { rows.append(.host) }
        rows += [.username, .password]
        return rows
    }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Email & Kindle"
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .account: return 1 /* provider */ + accountRows.count
        case .kindle: return 3 /* mode, kindle address, test send */
        case .importMail: return 2 /* enabled, auto-send */ + IncomingMailSettings.allowedSenders.count + 1 /* add */
        case .subjectFilters: return IncomingMailSettings.subjectFilters.count + 1 /* add */
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .account: return "Email Account"
        case .kindle: return "Send to Kindle"
        case .importMail: return "Import from Email"
        case .subjectFilters: return "Subject Filters"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .account:
            return "Used for both sending to Kindle and importing email. For Gmail, use an app password (myaccount.google.com → Security → App passwords).\n\nAll your email data stays local on this device, unless forwarded to Kindle via your email server."
        case .kindle:
            return "Amazon only accepts mail from approved senders — add this account at amazon.com → Preferences → Personal Document Settings."
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

        switch Section(rawValue: indexPath.section)! {
        case .account:
            if indexPath.row == 0 {
                content.text = "Provider"
                let control = UISegmentedControl(
                    items: KindleSendSettings.Provider.allCases.map(\.displayName))
                control.selectedSegmentIndex = KindleSendSettings.Provider.allCases
                    .firstIndex(of: KindleSendSettings.provider) ?? 0
                control.addTarget(self, action: #selector(providerChanged(_:)), for: .valueChanged)
                cell.accessoryView = control
                cell.contentConfiguration = content
                return cell
            }
            switch accountRows[indexPath.row - 1] {
            case .host:
                return fieldCell("Server", placeholder: "smtp.example.com",
                                 text: KindleSendSettings.customHost, field: .host)
            case .username:
                return fieldCell("Email", placeholder: "you@gmail.com",
                                 text: KindleSendSettings.smtpUsername, field: .username)
            case .password:
                return fieldCell("Password", placeholder: "App password",
                                 text: KeychainSendCredentialsStore.shared.smtpPassword() ?? "",
                                 field: .password, secure: true)
            case .kindleAddress:
                break
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
        switch Section(rawValue: indexPath.section)! {
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
        switch Section(rawValue: indexPath.section) {
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
        switch Section(rawValue: indexPath.section) {
        case .importMail:
            IncomingMailSettings.removeSender(at: indexPath.row - 2)
        case .subjectFilters:
            IncomingMailSettings.removeSubjectFilter(at: indexPath.row)
        default:
            return
        }
        tableView.deleteRows(at: [indexPath], with: .automatic)
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
        case .host: KindleSendSettings.customHost = value
        case .username: KindleSendSettings.smtpUsername = value
        case .password: KeychainSendCredentialsStore.shared.setSMTPPassword(value)
        case .kindleAddress: KindleSendSettings.kindleAddress = value
        case nil: break
        }
    }

    @objc private func providerChanged(_ control: UISegmentedControl) {
        let providers = KindleSendSettings.Provider.allCases
        KindleSendSettings.provider = providers[max(0, min(control.selectedSegmentIndex, providers.count - 1))]
        tableView.reloadData()
    }

    @objc private func importToggled(_ toggle: DotMatrixSwitch) {
        IncomingMailSettings.isEnabled = toggle.isOn
        if toggle.isOn { Task { await IncomingMailImporter.shared.importNewMail() } }
    }

    @objc private func autoSendToggled(_ toggle: DotMatrixSwitch) {
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

    private func sendTestEmail() {
        guard ArticleSendCoordinator.shared.isConfigured(destinationID: ArticleDestinationID.kindle) else {
            presentInfoAlert(title: "Not Configured",
                             message: "Fill in the email account and Kindle address first.")
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
