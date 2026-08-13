//
//  EmailAndKindleSettingsScreen.swift
//  Luna
//

import LunaReadingListUI
import LunaReadingList
import LunaMailTransport
import LunaMailAccount
import LunaSend
import LunaModels
import LunaDesignSystem
import UIKit

/// Email settings. This is also where an email account gets connected:
/// until one is, the Sharing Account section IS the sign-in form (an inline
/// address field + Connect). Everything that needs an account routes here.
final class EmailAndKindleSettingsScreen: NavHeaderTableController {

    private enum Section: Int, CaseIterable {
        case lunaAccount, importMail, subjectFilters
    }

    private enum ConnectedAccountRow {
        case account, issue, reconnect, inboxFilter, signOut
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

    /// The account this screen reads, signs in to, and signs out of. Injectable so
    /// tests can exercise the inline sign-in form without touching the App Group
    /// Keychain; every caller in the app uses the shared store.
    private let accountStore: EmailAccountStore

    private var connectedAccountRows: [ConnectedAccountRow] {
        guard accountStore.isConfigured else { return [] }
        if accountStore.authenticationIssue != nil {
            return [.account, .issue, .reconnect, .signOut]
        }
        return [.account, .inboxFilter, .signOut]
    }

    init(accountStore: EmailAccountStore = .shared) {
        self.accountStore = accountStore
        super.init(style: .insetGrouped)
    }

    #if DEBUG
    /// Staged mode's only seam into this screen (`claudedocs/staging.md`).
    /// Connecting is otherwise a state only a live sign-in attempt can produce
    /// — it is set from `EmailAccountSetup`'s busy callback and cleared when
    /// the network answers — so there is no way to hold a capture on the
    /// spinner without one. Nothing but a stage calls this.
    func setConnectingForStaging(_ connecting: Bool) {
        isConnecting = connecting
    }
    #endif
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
        headerTitle = L10n.string("Common_email")
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        NotificationCenter.default.addObserver(
            self, selector: #selector(accountStatusChanged),
            name: EmailAccountStore.accountChanged, object: nil)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Swap the sign-in form for the connected-account rows after a
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
        // Pushing while the prerequisite alert is still dismissing can make
        // UIKit accept first-responder status before it is willing to present
        // the keyboard. Retry once after both transitions have settled.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, self.view.window != nil, !self.accountStore.isConfigured else {
                return
            }
            self.addressField.becomeFirstResponder()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .lunaAccount:
            // Connected: account status/actions. Otherwise the inline sign-in
            // form: address field + Connect.
            return accountStore.isConfigured ? connectedAccountRows.count : 2
        case .importMail: return 2 /* enabled, auto-send */ + IncomingMailSettings.allowedSenders.count + 1 /* add */
        case .subjectFilters: return IncomingMailSettings.subjectFilters.count + 1 /* add */
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .lunaAccount: return L10n.string("Settings_email_accountSectionHeader")
        case .importMail: return L10n.string("Settings_email_importFromEmailLabel")
        case .subjectFilters: return L10n.string("Settings_email_subjectFiltersSectionHeader")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .lunaAccount:
            if accountStore.authenticationIssue != nil {
                return L10n.string("Settings_email_accountFooterIssue")
            }
            guard !accountStore.isConfigured else {
                return L10n.string("Settings_email_accountFooterConnected")
            }
            return L10n.string("Settings_email_accountFooterUnconfigured")
        case .importMail:
            return L10n.string("Settings_email_importFooter")
        case .subjectFilters:
            return L10n.string("Settings_email_subjectFiltersFooter")
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
        case .lunaAccount:
            if accountStore.isConfigured {
                switch connectedAccountRows[indexPath.row] {
                case .account:
                    content.text = accountStore.account?.address
                    content.secondaryText = accountStore.authenticationIssue == nil
                        ? accountStore.account?.provider.displayName
                        : L10n.string("Common_signInRequired")
                case .issue:
                    content.text = L10n.string("Settings_email_issueTitle")
                    content.secondaryText = authenticationIssueMessage
                    content.image = UIImage(systemName: "exclamationmark.triangle.fill")
                    content.imageProperties.tintColor = .systemOrange
                    content.textProperties.color = .systemOrange
                case .reconnect:
                    content.text = L10n.string("Settings_email_reconnectLabel")
                    content.secondaryText = L10n.string("Settings_email_reconnectSecondary")
                    content.image = UIImage(systemName: "person.badge.key")
                    content.textProperties.color = view.tintColor ?? .systemBlue
                    cell.selectionStyle = isConnecting ? .none : .default
                    if isConnecting {
                        let spinner = HorizonSpinnerView(side: 20)
                        spinner.startAnimating()
                        cell.accessoryView = spinner
                    } else {
                        cell.accessoryType = .disclosureIndicator
                    }
                case .inboxFilter:
                    content.text = L10n.string("Settings_email_inboxFilterLabel")
                    content.secondaryText = L10n.string("Settings_email_inboxFilterSecondary")
                    cell.accessoryType = .disclosureIndicator
                    cell.selectionStyle = .default
                case .signOut:
                    content.text = L10n.string("Settings_email_signOutLabel")
                    content.textProperties.color = .systemRed
                    cell.selectionStyle = .default
                }
            } else if indexPath.row == 0 {
                return addressEntryCell()
            } else {
                content.text = L10n.string("Settings_email_connectButton")
                content.textProperties.color = canConnect
                    ? (view.tintColor ?? .systemBlue) : LunaColors.tertiaryText
                content.image = UIImage(systemName: "person.badge.key")
                cell.selectionStyle = canConnect ? .default : .none
                if isConnecting {
                    let spinner = HorizonSpinnerView(side: 20)
                    spinner.startAnimating()
                    cell.accessoryView = spinner
                }
            }

        case .importMail:
            switch indexPath.row {
            case 0:
                content.text = L10n.string("Settings_email_importFromEmailLabel")
                cell.accessoryView = makeToggle(
                    isOn: IncomingMailSettings.isEnabled, action: #selector(importToggled(_:)))
            case 1:
                content.text = L10n.string("Settings_email_autoSendToKindleLabel")
                cell.accessoryView = makeToggle(
                    isOn: IncomingMailSettings.autoSendToKindle, action: #selector(autoSendToggled(_:)))
            default:
                let senderIndex = indexPath.row - 2
                if senderIndex < IncomingMailSettings.allowedSenders.count {
                    content.text = IncomingMailSettings.allowedSenders[senderIndex]
                } else {
                    content.text = L10n.string("Settings_email_addSenderRow")
                    content.textProperties.color = view.tintColor ?? .systemBlue
                    cell.selectionStyle = .default
                }
            }

        case .subjectFilters:
            if indexPath.row < IncomingMailSettings.subjectFilters.count {
                content.text = IncomingMailSettings.subjectFilters[indexPath.row]
            } else {
                content.text = L10n.string("Settings_email_addSubjectFilterRow")
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
        case .lunaAccount:
            if accountStore.isConfigured {
                switch connectedAccountRows[indexPath.row] {
                case .reconnect:
                    reconnectAccount()
                case .inboxFilter:
                    presentFilterGuide()
                case .signOut:
                    accountStore.clear()
                    tableView.reloadData()
                default:
                    break
                }
            } else if indexPath.row == 1 {
                connectAccount()
            }
        case .importMail where indexPath.row - 2 == IncomingMailSettings.allowedSenders.count:
            promptForSender()
        case .subjectFilters where indexPath.row == IncomingMailSettings.subjectFilters.count:
            promptForSubjectFilter()
        default:
            break
        }
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        switch Section(rawValue: indexPath.section)! {
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
        switch Section(rawValue: indexPath.section)! {
        case .importMail:
            IncomingMailSettings.removeSender(at: indexPath.row - 2)
        case .subjectFilters:
            IncomingMailSettings.removeSubjectFilter(at: indexPath.row)
        default:
            return
        }
        tableView.deleteRows(at: [indexPath], with: .automatic)
    }

    // MARK: - Inline account sign-in

    /// Whether the address as typed is worth a network round trip.
    private var canConnect: Bool {
        !isConnecting && EmailAccountSetup.isValidAddress(addressField.text ?? "")
    }

    private var authenticationIssueMessage: String {
        switch accountStore.authenticationIssue {
        case .credentialsRejected:
            return L10n.string("Settings_email_issueCredentialsRejected")
        case .authorizationExpired:
            return L10n.string("Settings_email_issueAuthorizationExpired")
        case nil:
            return ""
        }
    }

    private func makeAddressField() -> UITextField {
        let field = UITextField()
        field.placeholder = L10n.string("Common_emailPlaceholderExample")
        field.font = .preferredFont(forTextStyle: .body)
        field.keyboardType = .emailAddress
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        // Prefer the system's fast personal-email suggestion over the credential
        // manager UI. AutoFill insertion stays native because this field has no
        // delegate and starts its input session only once hosted in the window.
        field.textContentType = .emailAddress
        field.returnKeyType = .go
        field.textAlignment = .left
        field.textColor = LunaColors.primaryText
        field.translatesAutoresizingMaskIntoConstraints = false
        // Keep the delegate nil — in particular, don't interpose on the iOS 26
        // input-suggestion/replacement path used by credential providers. The
        // return key needs only a control action.
        field.addTarget(self, action: #selector(connectAccount), for: .editingDidEndOnExit)
        field.addTarget(self, action: #selector(addressEdited), for: .editingChanged)
        return field
    }

    /// The sign-in form's first row, matching the rounded field card in the
    /// former tray email setup.
    private func addressEntryCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.backgroundColor = .clear
        let fieldCard = EmailLoginUI.fieldCard()
        let glyph = EmailLoginUI.leadingGlyph("envelope")

        // Re-hosting the same two long-lived views: removing them from the
        // previous cell drops that cell's constraints on them too.
        addressField.removeFromSuperview()
        addressBadge.removeFromSuperview()
        cell.contentView.addSubview(fieldCard)
        fieldCard.addSubview(glyph)
        fieldCard.addSubview(addressField)
        fieldCard.addSubview(addressBadge)
        NSLayoutConstraint.activate([
            fieldCard.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
            fieldCard.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
            fieldCard.leadingAnchor.constraint(
                equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            fieldCard.trailingAnchor.constraint(
                equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            glyph.leadingAnchor.constraint(equalTo: fieldCard.leadingAnchor, constant: 15),
            glyph.centerYAnchor.constraint(equalTo: fieldCard.centerYAnchor),
            addressField.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 10),
            addressField.trailingAnchor.constraint(equalTo: addressBadge.leadingAnchor, constant: -8),
            addressField.centerYAnchor.constraint(equalTo: fieldCard.centerYAnchor),
            // The badge stays installed and only fades, so it never jumps layout.
            addressBadge.trailingAnchor.constraint(
                equalTo: fieldCard.trailingAnchor, constant: -12),
            addressBadge.centerYAnchor.constraint(equalTo: fieldCard.centerYAnchor),
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
              let section = Section.allCases.firstIndex(of: .lunaAccount),
              tableView.numberOfSections > section,
              tableView.numberOfRows(inSection: section) > 1
        else { return }
        tableView.reloadRows(at: [IndexPath(row: 1, section: section)], with: .none)
    }

    @objc private func accountStatusChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.accountStatusChanged() }
            return
        }
        guard isViewLoaded else { return }
        tableView.reloadData()
    }

    @objc private func connectAccount() {
        guard !isConnecting else { return }
        guard EmailAccountSetup.isValidAddress(addressField.text ?? "") else {
            addressField.shake()
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        addressField.resignFirstResponder()
        beginAccountSetup(address: addressField.text ?? "", clearsAddressOnSuccess: true)
    }

    private func reconnectAccount() {
        guard !isConnecting, let account = accountStore.account else { return }
        beginAccountSetup(
            address: account.address,
            existingAccount: account,
            clearsAddressOnSuccess: false)
    }

    private func beginAccountSetup(
        address: String,
        existingAccount: EmailAccount? = nil,
        clearsAddressOnSuccess: Bool
    ) {
        let setup = EmailAccountSetup(
            presenter: self,
            accountStore: accountStore,
            onBusyChange: { [weak self] busy in
                guard let self else { return }
                self.isConnecting = busy
                if self.accountStore.isConfigured {
                    self.tableView.reloadSections(
                        IndexSet(integer: Section.lunaAccount.rawValue), with: .none)
                } else {
                    self.reloadConnectRow()
                }
            },
            completion: { [weak self] connected in
                guard let self else { return }
                self.isConnecting = false
                self.accountSetup = nil
                guard connected || self.accountStore.isReady else {
                    if self.accountStore.isConfigured {
                        self.tableView.reloadSections(
                            IndexSet(integer: Section.lunaAccount.rawValue), with: .none)
                    } else {
                        self.reloadConnectRow()
                    }
                    return
                }
                if clearsAddressOnSuccess { self.addressField.text = "" }
                // The credential screen stays on screen through its success
                // checkmark; come back to the (now connected) settings rows.
                if self.navigationController?.topViewController !== self {
                    self.navigationController?.popToViewController(self, animated: true)
                }
                self.tableView.reloadData()
            })
        accountSetup = setup
        let didStart: Bool
        if let existingAccount {
            didStart = setup.start(account: existingAccount)
        } else {
            didStart = setup.start(address: address)
        }
        if !didStart {
            accountSetup = nil
            isConnecting = false
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
            title: L10n.string("Settings_email_addSenderTitle"), message: L10n.string("Settings_email_addSenderMessage"),
            preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = L10n.string("Common_namePlaceholderExample")
            field.keyboardType = .emailAddress
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("Common_add"), style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text else { return }
            IncomingMailSettings.addSender(text)
            self?.tableView.reloadData()
        })
        present(alert, animated: true)
    }

    private func promptForSubjectFilter() {
        let alert = UIAlertController(
            title: L10n.string("Settings_email_addSubjectFilterTitle"),
            message: L10n.string("Settings_email_addSubjectFilterMessage"),
            preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = L10n.string("Settings_email_subjectFilterPlaceholder")
            field.autocapitalizationType = .sentences
            field.autocorrectionType = .default
        }
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("Common_add"), style: .default) { [weak self, weak alert] _ in
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
                title: L10n.string("Settings_email_filterActiveTitle"),
                message: L10n.string("Settings_email_filterActiveMessage"))
            return
        }
        let alert = UIAlertController(
            title: L10n.string("Settings_email_inboxFilterLabel"), message: FilterGuide.instructions(for: providerID),
            preferredStyle: .alert)
        if let url = FilterGuide.settingsURL(for: providerID) {
            alert.addAction(UIAlertAction(title: L10n.string("Settings_email_openFilterSettingsButton"), style: .default) { _ in
                UIApplication.shared.open(url)
            })
        }
        alert.addAction(UIAlertAction(title: L10n.string("Common_done"), style: .cancel))
        present(alert, animated: true)
    }

}

/// Kindle-specific forwarding, address, and test-send settings. The top-level
/// Settings menu gates this screen until the shared email account is connected.
final class KindleSettingsScreen: NavHeaderTableController {
    private lazy var kindleAddressField: UITextField = {
        let field = UITextField()
        field.placeholder = L10n.string("Settings_email_kindle_addressPlaceholder")
        field.text = KindleSendSettings.kindleAddress
        field.font = .preferredFont(forTextStyle: .body)
        field.textColor = LunaColors.primaryText
        field.keyboardType = .emailAddress
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.textContentType = .emailAddress
        field.returnKeyType = .done
        field.addTarget(self, action: #selector(addressEdited), for: .editingChanged)
        field.addTarget(self, action: #selector(addressEdited), for: .editingDidEnd)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = L10n.string("Common_kindle")
        super.viewDidLoad()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        3
    }

    override func tableView(
        _ tableView: UITableView, titleForHeaderInSection section: Int
    ) -> String? {
        L10n.string("Common_sendToKindle")
    }

    override func tableView(
        _ tableView: UITableView, titleForFooterInSection section: Int
    ) -> String? {
        L10n.string("Settings_email_kindle_footer")
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch indexPath.row {
        case 0:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = L10n.string("Settings_email_kindle_forwardingSettingsRow")
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        case 1:
            return kindleAddressCell()
        default:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = L10n.string("Settings_email_kindle_sendTestRow")
            content.textProperties.color = view.tintColor ?? .systemBlue
            content.image = UIImage(systemName: "paperplane")
            cell.contentConfiguration = content
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch indexPath.row {
        case 0:
            navigationController?.pushViewController(
                AutoSendBySourceScreen(
                    destinationID: ArticleDestinationID.kindle,
                    destinationName: L10n.string("Common_kindle")),
                animated: true)
        case 2:
            sendTestEmail()
        default:
            break
        }
    }

    private func kindleAddressCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        let label = UILabel()
        label.text = L10n.string("Common_kindle")
        label.font = .preferredFont(forTextStyle: .body)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)

        kindleAddressField.removeFromSuperview()
        cell.contentView.addSubview(label)
        cell.contentView.addSubview(kindleAddressField)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            kindleAddressField.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            kindleAddressField.trailingAnchor.constraint(
                equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            kindleAddressField.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return cell
    }

    @objc private func addressEdited() {
        KindleSendSettings.kindleAddress = (kindleAddressField.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendTestEmail() {
        guard ArticleSendCoordinator.shared.isConfigured(
            destinationID: ArticleDestinationID.kindle
        ) else {
            presentInfoAlert(
                title: L10n.string("Settings_email_kindle_notConfiguredTitle"),
                message: L10n.string("Settings_email_kindle_notConfiguredMessage"))
            return
        }
        Task { [weak self] in
            do {
                try await ArticleSendCoordinator.shared.sendTestDocument(
                    toDestinationID: ArticleDestinationID.kindle)
                self?.presentInfoAlert(
                    title: L10n.string("Settings_email_kindle_testSentTitle"),
                    message: L10n.string("Settings_email_kindle_testSentMessage"))
            } catch {
                self?.presentInfoAlert(
                    title: L10n.string("Settings_email_testSendFailedTitle"), message: "\(error)")
            }
        }
    }
}
