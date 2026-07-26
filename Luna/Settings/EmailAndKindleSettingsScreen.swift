//
//  EmailAndKindleSettingsScreen.swift
//  Luna
//

import LunaReadingListUI
import LunaReadingList
import LunaMail
import LunaMailAccount
import LunaSend
import LunaModels
import LunaSocial
import LunaStorage
import LunaDesignSystem
import UIKit

/// Email & Sending settings. This is also where an email account gets connected:
/// until one is, the Sharing Account section IS the sign-in form (an inline
/// address field + Connect), and everything that needs an account to send —
/// `SendToFriendSheet`, Send to Kindle — routes the user here. Includes the
/// Reader-only Double Save action (send to Kindle / friend when the same link is
/// saved twice with the Action Button — see `claudedocs/double-save.md`).
final class EmailAndKindleSettingsScreen: NavHeaderTableController {

    private enum Section: Int, CaseIterable {
        case lunaAccount, kindle, doubleSave, importMail, subjectFilters
    }

    /// Set by a caller that sent the user here to connect an account (the
    /// unconfigured-send redirect), so the address field takes the keyboard as
    /// soon as the screen appears. One-shot.
    var focusesAddressField = false

    /// The inline sign-in field and its provider chip. Long-lived rather than
    /// built per cell: `viewWillAppear` reloads the table, and a freshly built
    /// field would drop both the half-typed address and the keyboard session.
    private lazy var addressField = makeAddressField()
    private lazy var addressBadge = ProviderBadgeView()
    /// Non-nil only while a sign-in attempt is in flight (it owns the OAuth
    /// session / autodiscovery task).
    private var accountSetup: EmailAccountSetup?
    private var isConnecting = false

    /// The double-save action only fires for Reader's Action Button saves, so
    /// its section only shows there.
    private var visibleSections: [Section] {
        Section.allCases.filter { $0 != .doubleSave || AppSurfaceConfig.current == .reader }
    }

    private var doubleSaveSurface: String { AppSurfaceConfig.current.storageIdentifier }

    /// Field tags for the text fields.
    private enum Field: Int { case kindleAddress = 1 }

    /// The account this screen reads, signs in to, and signs out of. Injectable so
    /// tests can exercise the inline sign-in form without touching the App Group
    /// Keychain; every caller in the app uses the shared store.
    private let accountStore: EmailAccountStore

    init(accountStore: EmailAccountStore = .shared) {
        self.accountStore = accountStore
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The one destination for "this needs an email account first": pushes this
    /// screen with the inline sign-in field already focused. Installed as
    /// `SendToFriendSheet.accountSetupLauncher` by the `KindWiring` variants of the
    /// apps that send email.
    static func pushForAccountSetup(from presenter: UIViewController) {
        let screen = EmailAndKindleSettingsScreen()
        screen.focusesAddressField = true
        if let nav = presenter.navigationController {
            nav.pushViewController(screen, animated: true)
        } else {
            presenter.present(UINavigationController(rootViewController: screen), animated: true)
        }
    }

    override func viewDidLoad() {
        headerTitle = L10n.string("Email & Sending")
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Refresh value rows edited on pushed subscreens (double-save recipients),
        // and swap the sign-in form for the connected-account rows after a
        // successful sign-in on a pushed credential screen.
        tableView.reloadData()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        // Only once the field is attached to the window: starting the input
        // session earlier can leave the keyboard's email suggestion bar bound to
        // a provisional session that never delivers its tap to this field.
        guard focusesAddressField, !accountStore.isConfigured else { return }
        focusesAddressField = false
        addressField.becomeFirstResponder()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { visibleSections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch visibleSections[section] {
        case .lunaAccount:
            // Connected: address, inbox filter, sign out. Otherwise the inline
            // sign-in form: address field + Connect.
            return accountStore.isConfigured ? 3 : 2
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
        case .lunaAccount: return L10n.string("Sharing Account")
        case .kindle: return L10n.string("Send to Kindle")
        case .doubleSave: return L10n.string("Double Save")
        case .importMail: return L10n.string("Import from Email")
        case .subjectFilters: return L10n.string("Subject Filters")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch visibleSections[section] {
        case .lunaAccount:
            let base = L10n.string(
                "Connect any email provider (Gmail, iCloud, Yahoo, Outlook, or a custom IMAP server) to send articles to contacts and import shares sent to you.")
            guard !accountStore.isConfigured else { return base }
            return L10n.string(
                "Connect any email provider (Gmail, iCloud, Yahoo, Outlook, or a custom IMAP server) to send articles to contacts and import shares sent to you.\n\nEnter your address above; Luna asks for an app-specific password (or signs in with Outlook) next.")
        case .kindle:
            return L10n.string("Articles are emailed from the connected Luna email account (the section at the top of this screen). That address must be on Amazon's approved-sender list (amazon.com → Preferences → Personal Document Settings), and sending requires the account to be connected.")
        case .doubleSave:
            return L10n.string("Saving the same link twice within 7 seconds with the Action Button shortcut runs this action on the already-saved article.")
        case .importMail:
            return L10n.string("New email from matching senders becomes a reading-list item, optionally forwarding to Kindle automatically overnight.")
        case .subjectFilters:
            return L10n.string("Also import any email whose subject contains one of these phrases, regardless of sender.")
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
            if accountStore.isConfigured {
                switch indexPath.row {
                case 0:
                    content.text = accountStore.account?.address
                    content.secondaryText = accountStore.account?.provider.displayName
                case 1:
                    content.text = L10n.string("Inbox Filter")
                    content.secondaryText = L10n.string("Keep Luna mail out of your inbox")
                    cell.accessoryType = .disclosureIndicator
                    cell.selectionStyle = .default
                default:
                    content.text = L10n.string("Sign Out")
                    content.textProperties.color = .systemRed
                    cell.selectionStyle = .default
                }
            } else if indexPath.row == 0 {
                return addressEntryCell()
            } else {
                content.text = L10n.string("Connect")
                content.textProperties.color = canConnect
                    ? (view.tintColor ?? .systemBlue) : LunaColors.tertiaryText
                content.image = UIImage(systemName: "person.badge.key")
                cell.selectionStyle = canConnect ? .default : .none
                if isConnecting {
                    let spinner = DotMatrixSpinnerView(dimension: 4, side: 20)
                    spinner.startAnimating()
                    cell.accessoryView = spinner
                }
            }

        case .kindle:
            switch indexPath.row {
            case 0:
                content.text = L10n.string("Kindle forwarding settings")
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            case 1:
                return fieldCell("Kindle", placeholder: L10n.string("name@kindle.com"),
                                 text: KindleSendSettings.kindleAddress, field: .kindleAddress)
            default:
                content.text = L10n.string("Send Test to Kindle")
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
                content.text = L10n.string("Recipients")
                content.secondaryText = doubleSaveRecipientsSummary()
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            }

        case .importMail:
            switch indexPath.row {
            case 0:
                content.text = L10n.string("Import from Email")
                cell.accessoryView = makeToggle(
                    isOn: IncomingMailSettings.isEnabled, action: #selector(importToggled(_:)))
            case 1:
                content.text = L10n.string("Also Send to Kindle")
                cell.accessoryView = makeToggle(
                    isOn: IncomingMailSettings.autoSendToKindle, action: #selector(autoSendToggled(_:)))
            default:
                let senderIndex = indexPath.row - 2
                if senderIndex < IncomingMailSettings.allowedSenders.count {
                    content.text = IncomingMailSettings.allowedSenders[senderIndex]
                } else {
                    content.text = L10n.string("Add Sender…")
                    content.textProperties.color = view.tintColor ?? .systemBlue
                    cell.selectionStyle = .default
                }
            }

        case .subjectFilters:
            if indexPath.row < IncomingMailSettings.subjectFilters.count {
                content.text = IncomingMailSettings.subjectFilters[indexPath.row]
            } else {
                content.text = L10n.string("Add Subject Filter…")
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
            if accountStore.isConfigured {
                switch indexPath.row {
                case 1: presentFilterGuide()
                case 2:
                    accountStore.clear()
                    tableView.reloadData()
                default: break
                }
            } else if indexPath.row == 1 {
                connectAccount()
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
                    destinationID: ArticleDestinationID.kindle,
                    destinationName: L10n.string("Kindle")),
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
            return L10n.string("Ask Every Time")
        }
        let emails = store.presetFriendEmails(forSurface: doubleSaveSurface)
        guard !emails.isEmpty else { return L10n.string("Ask Every Time") }
        let names = emails.map { email in
            FriendsStore.shared.friend(withEmail: email)?.displayName ?? Friend.localPart(email)
        }
        return names.count <= 2 ? names.joined(separator: ", ") : "\(names.count) Contacts"
    }

    // MARK: - Inline account sign-in

    /// Whether the address as typed is worth a network round trip.
    private var canConnect: Bool {
        !isConnecting && EmailAccountSetup.isValidAddress(addressField.text ?? "")
    }

    private func makeAddressField() -> UITextField {
        let field = UITextField()
        field.placeholder = L10n.string("you@example.com")
        field.font = .preferredFont(forTextStyle: .body)
        field.keyboardType = .emailAddress
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        // Prefer the system's fast personal-email suggestion over the credential
        // manager UI. AutoFill insertion stays native because this field has no
        // delegate and starts its input session only once hosted in the window.
        field.textContentType = .emailAddress
        field.returnKeyType = .go
        field.textAlignment = .right
        field.textColor = LunaColors.secondaryText
        field.translatesAutoresizingMaskIntoConstraints = false
        // Keep the delegate nil — in particular, don't interpose on the iOS 26
        // input-suggestion/replacement path used by credential providers. The
        // return key needs only a control action.
        field.addTarget(self, action: #selector(connectAccount), for: .editingDidEndOnExit)
        field.addTarget(self, action: #selector(addressEdited), for: .editingChanged)
        return field
    }

    /// The sign-in form's first row: label, the inline address field, and the
    /// provider chip that appears once the domain is recognized.
    private func addressEntryCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        let nameLabel = UILabel()
        nameLabel.text = L10n.string("Email")
        nameLabel.font = .preferredFont(forTextStyle: .body)
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)
        nameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Re-hosting the same two long-lived views: removing them from the
        // previous cell drops that cell's constraints on them too.
        addressField.removeFromSuperview()
        addressBadge.removeFromSuperview()
        cell.contentView.addSubview(nameLabel)
        cell.contentView.addSubview(addressField)
        cell.contentView.addSubview(addressBadge)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            addressField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 12),
            addressField.trailingAnchor.constraint(equalTo: addressBadge.leadingAnchor, constant: -8),
            addressField.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            // The badge stays installed and only fades, so it never jumps layout.
            addressBadge.trailingAnchor.constraint(
                equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            addressBadge.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        addressEdited()
        return cell
    }

    @objc private func addressEdited() {
        let address = (addressField.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        addressBadge.setProvider(
            ProviderBadgeText.text(for: ProviderInference.inferProviderID(for: address)))
        reloadConnectRow()
    }

    /// Repaints just the Connect row (enablement + spinner) without rebuilding the
    /// address cell, which would interrupt typing.
    private func reloadConnectRow() {
        guard !accountStore.isConfigured,
              let section = visibleSections.firstIndex(of: .lunaAccount),
              tableView.numberOfSections > section,
              tableView.numberOfRows(inSection: section) > 1
        else { return }
        tableView.reloadRows(at: [IndexPath(row: 1, section: section)], with: .none)
    }

    @objc private func connectAccount() {
        guard !isConnecting else { return }
        guard EmailAccountSetup.isValidAddress(addressField.text ?? "") else {
            addressField.shake()
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        addressField.resignFirstResponder()
        let setup = EmailAccountSetup(
            presenter: self,
            accountStore: accountStore,
            onBusyChange: { [weak self] busy in
                self?.isConnecting = busy
                self?.reloadConnectRow()
            },
            completion: { [weak self] connected in
                guard let self else { return }
                self.isConnecting = false
                self.accountSetup = nil
                guard connected else { self.reloadConnectRow(); return }
                self.addressField.text = ""
                // The credential screen stays on screen through its success
                // checkmark; come back to the (now connected) settings rows.
                if self.navigationController?.topViewController !== self {
                    self.navigationController?.popToViewController(self, animated: true)
                }
                self.tableView.reloadData()
            })
        accountSetup = setup
        setup.start(address: addressField.text ?? "")
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
        textField.textColor = LunaColors.secondaryText
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
            title: L10n.string("Add Sender"), message: L10n.string("Emails from this address will be imported."),
            preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = L10n.string("name@example.com")
            field.keyboardType = .emailAddress
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: L10n.string("Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("Add"), style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text else { return }
            IncomingMailSettings.addSender(text)
            self?.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    private func promptForSubjectFilter() {
        let alert = UIAlertController(
            title: L10n.string("Add Subject Filter"),
            message: L10n.string("Email whose subject contains this phrase will be imported, regardless of sender."),
            preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = L10n.string("Subject contains…")
            field.autocapitalizationType = .sentences
            field.autocorrectionType = .default
        }
        alert.addAction(UIAlertAction(title: L10n.string("Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("Add"), style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text else { return }
            IncomingMailSettings.addSubjectFilter(text)
            self?.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    private func presentFilterGuide() {
        guard let providerID = accountStore.account?.providerID else { return }
        if FilterGuide.isAutomatic(providerID) {
            presentInfoAlert(
                title: L10n.string("Filter Active"),
                message: L10n.string("Luna set up an inbox rule automatically for this account."))
            return
        }
        let alert = UIAlertController(
            title: L10n.string("Inbox Filter"), message: FilterGuide.instructions(for: providerID),
            preferredStyle: .alert)
        if let url = FilterGuide.settingsURL(for: providerID) {
            alert.addAction(UIAlertAction(title: L10n.string("Open Filter Settings"), style: .default) { _ in
                UIApplication.shared.open(url)
            })
        }
        alert.addAction(UIAlertAction(title: L10n.string("Done"), style: .cancel))
        present(alert, animated: true)
    }

    // MARK: - Test sends

    private func sendTestEmail() {
        guard ArticleSendCoordinator.shared.isConfigured(destinationID: ArticleDestinationID.kindle) else {
            presentInfoAlert(title: L10n.string("Not Configured"),
                             message: L10n.string("Connect an email account and enter your Kindle address first."))
            return
        }
        Task { [weak self] in
            do {
                try await ArticleSendCoordinator.shared.sendTestDocument(
                    toDestinationID: ArticleDestinationID.kindle)
                self?.presentInfoAlert(
                    title: L10n.string("Test Sent"),
                    message: L10n.string("Check your Kindle library in a few minutes. If nothing arrives, confirm the sender is on Amazon's approved list."))
            } catch {
                self?.presentInfoAlert(title: L10n.string("Test Failed"), message: L10n.string("\(error)"))
            }
        }
    }

}
