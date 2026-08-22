//
//  XteinkSettingsScreen.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import LunaSend
import LunaStorage
import Security
import UIKit

/// Send-to-Xteink settings: the enable switch, BLE pairing, per-source
/// auto-send, and a manual sweep of everything queued. Unlike Kindle there is
/// no email prerequisite — delivery goes over the CrossPoint BLE rendezvous or
/// a same-network Wi-Fi upload.
final class XteinkSettingsScreen: NavHeaderTableController {

    private enum Section: Int, CaseIterable { case setup, transfer }
    private enum SetupRow: Int, CaseIterable { case enable, pair, autoSend }
    private enum TransferRow: Int, CaseIterable { case transferNow }

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
            case .pair:
                let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
                var content = cell.defaultContentConfiguration()
                content.text = L10n.string("Settings_xteink_pairRow")
                content.secondaryText = L10n.string("Settings_xteink_pairDetail")
                cell.contentConfiguration = content
                cell.accessoryType = .disclosureIndicator
                return cell
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
            switch SetupRow(rawValue: indexPath.row)! {
            case .pair: presentPairingPrompt()
            case .autoSend:
                navigationController?.pushViewController(
                    AutoSendBySourceScreen(
                        destinationID: ArticleDestinationID.xteink,
                        destinationName: L10n.string("Common_xteink")),
                    animated: true)
            case .enable: break
            }
        case .transfer:
            switch TransferRow(rawValue: indexPath.row)! {
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

    // MARK: - Actions

    @objc private func enableToggled(_ toggle: UISwitch) {
        XteinkSendSettings.isEnabled = toggle.isOn
        guard toggle.isOn else { return }
        XteinkBLECentral.shared.beginRendezvousScan()
    }

    private func presentPairingPrompt() {
        let alert = UIAlertController(
            title: L10n.string("Settings_xteink_pairTitle"),
            message: L10n.string("Settings_xteink_pairMessage"), preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = L10n.string("Settings_xteink_pairCodePlaceholder")
            field.keyboardType = .numberPad
        }
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("Settings_xteink_pairConfirm"), style: .default) {
            [weak self, weak alert] _ in
            guard let self, let code = alert?.textFields?.first?.text,
                  !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            Task { @MainActor in
                do {
                    try await XteinkBLECentral.shared.pair(code: code, pairSecret: Self.pairSecret())
                    XteinkSendSettings.isEnabled = true
                    self.tableView.reloadData()
                    self.presentInfoAlert(title: L10n.string("Settings_xteink_pairSuccessTitle"), message: L10n.string("Settings_xteink_pairSuccessMessage"))
                } catch {
                    self.presentInfoAlert(title: L10n.string("Settings_email_testSendFailedTitle"), message: "\(error)")
                }
            }
        })
        present(alert, animated: true)
    }

    private static func pairSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
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
