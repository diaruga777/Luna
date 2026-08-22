//
//  XteinkSettingsScreen.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import LunaSend
import LunaStorage
import UIKit

/// Send-to-Xteink settings: the enable switch, the device address, per-source
/// auto-send, a test transfer, and a manual sweep of everything queued. Unlike
/// Kindle there is no email prerequisite — delivery is a direct upload to the
/// e-reader's Wi-Fi file manager.
final class XteinkSettingsScreen: NavHeaderTableController {

    private enum Section: Int, CaseIterable { case setup, transfer }
    private enum SetupRow: Int, CaseIterable { case enable, address, autoSend }
    private enum TransferRow: Int, CaseIterable { case sendTest, transferNow }

    private lazy var addressField: UITextField = {
        let field = UITextField()
        field.placeholder = XteinkSendSettings.defaultDeviceAddress
        field.text = XteinkSendSettings.deviceAddress
        field.font = .preferredFont(forTextStyle: .body)
        field.textColor = LunaColors.primaryText
        field.keyboardType = .URL
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.returnKeyType = .done
        field.addTarget(self, action: #selector(addressEdited), for: .editingChanged)
        field.addTarget(self, action: #selector(addressEdited), for: .editingDidEnd)
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }()

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = L10n.string("Common_xteink")
        super.viewDidLoad()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .setup: return SetupRow.allCases.count
        case .transfer: return TransferRow.allCases.count
        }
    }

    override func tableView(
        _ tableView: UITableView, titleForHeaderInSection section: Int
    ) -> String? {
        switch Section(rawValue: section)! {
        case .setup: return L10n.string("Common_sendToXteink")
        case .transfer: return L10n.string("Settings_xteink_transferSectionHeader")
        }
    }

    override func tableView(
        _ tableView: UITableView, titleForFooterInSection section: Int
    ) -> String? {
        switch Section(rawValue: section)! {
        case .setup: return L10n.string("Settings_xteink_setupFooter")
        case .transfer: return nil
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .setup:
            switch SetupRow(rawValue: indexPath.row)! {
            case .enable: return enableCell()
            case .address: return addressCell()
            case .autoSend:
                let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
                var content = cell.defaultContentConfiguration()
                content.text = L10n.string("Settings_xteink_autoSendRow")
                cell.contentConfiguration = content
                cell.accessoryType = .disclosureIndicator
                return cell
            }
        case .transfer:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.textProperties.color = view.tintColor ?? .systemBlue
            switch TransferRow(rawValue: indexPath.row)! {
            case .sendTest:
                content.text = L10n.string("Settings_xteink_sendTestRow")
                content.image = UIImage(systemName: "paperplane")
            case .transferNow:
                content.text = L10n.string("Settings_xteink_transferNowRow")
                content.image = UIImage(systemName: "arrow.up.doc")
            }
            cell.contentConfiguration = content
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Section(rawValue: indexPath.section)! {
        case .setup:
            if SetupRow(rawValue: indexPath.row) == .autoSend {
                navigationController?.pushViewController(
                    AutoSendBySourceScreen(
                        destinationID: ArticleDestinationID.xteink,
                        destinationName: L10n.string("Common_xteink")),
                    animated: true)
            }
        case .transfer:
            switch TransferRow(rawValue: indexPath.row)! {
            case .sendTest: sendTestDocument()
            case .transferNow: transferPendingNow()
            }
        }
    }

    // MARK: - Cells

    private func enableCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.text = L10n.string("Common_sendToXteink")
        cell.contentConfiguration = content
        let toggle = UISwitch()
        toggle.isOn = XteinkSendSettings.isEnabled
        toggle.addTarget(self, action: #selector(enableToggled(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    private func addressCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        let label = UILabel()
        label.text = L10n.string("Settings_xteink_addressLabel")
        label.font = .preferredFont(forTextStyle: .body)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentHuggingPriority(.required, for: .horizontal)

        addressField.removeFromSuperview()
        cell.contentView.addSubview(label)
        cell.contentView.addSubview(addressField)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            addressField.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 12),
            addressField.trailingAnchor.constraint(
                equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            addressField.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return cell
    }

    // MARK: - Actions

    @objc private func enableToggled(_ toggle: UISwitch) {
        XteinkSendSettings.isEnabled = toggle.isOn
        guard toggle.isOn else { return }
        // Probe once right away: the first local-network access is what makes
        // iOS show its permission prompt, and here the user is looking.
        Task.detached(priority: .utility) {
            _ = await XteinkDeviceClient().findDevice(
                among: XteinkSendSettings.candidateHosts)
        }
    }

    @objc private func addressEdited() {
        XteinkSendSettings.deviceAddress = (addressField.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func sendTestDocument() {
        guard XteinkSendSettings.isConfigured else {
            presentInfoAlert(
                title: L10n.string("Settings_xteink_notEnabledTitle"),
                message: L10n.string("Settings_xteink_notEnabledMessage"))
            return
        }
        Task { [weak self] in
            do {
                try await ArticleSendCoordinator.shared.sendTestDocument(
                    toDestinationID: ArticleDestinationID.xteink)
                self?.presentInfoAlert(
                    title: L10n.string("Settings_xteink_testSentTitle"),
                    message: L10n.string("Settings_xteink_testSentMessage"))
            } catch is XteinkDeviceClient.UnreachableError {
                self?.presentInfoAlert(
                    title: L10n.string("Settings_xteink_notReachableTitle"),
                    message: L10n.string("Settings_xteink_notReachableMessage"))
            } catch {
                self?.presentInfoAlert(
                    title: L10n.string("Settings_email_testSendFailedTitle"), message: "\(error)")
            }
        }
    }

    private func transferPendingNow() {
        let pending = SavesStore.shared.items().filter {
            $0.sendState(for: ArticleDestinationID.xteink) == .queued
        }.count
        guard pending > 0 else {
            presentInfoAlert(
                title: L10n.string("Settings_xteink_nothingPendingTitle"),
                message: L10n.string("Settings_xteink_nothingPendingMessage"))
            return
        }
        ArticleSendCoordinator.shared.retryPendingSends()
        presentInfoAlert(
            title: L10n.string("Settings_xteink_transferQueuedTitle"),
            message: L10n.string("Settings_xteink_transferQueuedMessage", pending))
    }
}
