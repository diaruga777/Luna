//
//  XteinkSettingsScreen.swift
//  Luna
//

import AccessorySetupKit
import CoreBluetooth
import LunaDesignSystem
import LunaModels
import LunaSend
import LunaStorage
import Security
import UIKit

/// Send-to-Xteink settings: the enable switch, BLE pairing, and per-source
/// auto-send. Delivery is device-initiated — the reader collects queued sends
/// only when it opens a Luna Sync window — so there is no phone-side "transfer
/// now" row.
final class XteinkSettingsScreen: NavHeaderTableController {

    private enum Section: Int, CaseIterable { case setup }
    private enum SetupRow: Equatable { case enable, pair, autoSend, unpair }

    private var setupRows: [SetupRow] {
        var rows: [SetupRow] = [.enable, .pair, .autoSend]
        if XteinkBLECentral.shared.isPaired { rows.append(.unpair) }
        return rows
    }

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
        setupRows.count
    }

    override func tableView(
        _ tableView: UITableView, titleForHeaderInSection section: Int
    ) -> String? {
        L10n.string("Common_sendToXteink")
    }

    override func tableView(
        _ tableView: UITableView, titleForFooterInSection section: Int
    ) -> String? {
        L10n.string("Settings_xteink_setupFooter")
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch setupRows[indexPath.row] {
        case .enable: return enableCell()
        case .pair:
            let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = L10n.string("Settings_xteink_pairRow")
            let paired = XteinkBLECentral.shared.isPaired
            content.secondaryText = L10n.string(paired ? "Settings_xteink_pairedDetail" : "Settings_xteink_pairDetail")
            if paired {
                let badge = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
                badge.tintColor = .systemGreen
                cell.accessoryView = badge
            } else {
                cell.accessoryType = .disclosureIndicator
            }
            cell.contentConfiguration = content
            return cell
        case .autoSend:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = L10n.string("Settings_xteink_autoSendRow")
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        case .unpair:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = cell.defaultContentConfiguration()
            content.text = L10n.string("Settings_xteink_unpairRow")
            content.textProperties.color = .systemRed
            cell.contentConfiguration = content
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch setupRows[indexPath.row] {
        case .pair: presentPairingPrompt()
        case .autoSend:
            navigationController?.pushViewController(
                AutoSendBySourceScreen(
                    destinationID: ArticleDestinationID.xteink,
                    destinationName: L10n.string("Common_xteink")),
                animated: true)
        case .unpair: presentUnpairConfirmation()
        case .enable: break
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

    /// Activated on first use so the app isn't holding a BLE discovery session
    /// open before the user ever opens this screen.
    private lazy var accessorySession: ASAccessorySession = {
        let session = ASAccessorySession()
        session.activate(on: .main) { [weak self] event in
            self?.handleAccessoryEvent(event)
        }
        return session
    }()

    private func presentPairingPrompt() {
        let alert = UIAlertController(
            title: L10n.string("Settings_xteink_pairTitle"),
            message: L10n.string("Settings_xteink_pairMessage"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("Settings_xteink_pairConfirm"), style: .default) {
            [weak self] _ in
            self?.showAccessoryPicker()
        })
        present(alert, animated: true)
    }

    /// True from the moment the picker reports a selection until that pairing
    /// settles, so the picker path can tell "cancelled" from "selection made".
    private var pairingInFlight = false

    /// Shows the system's AccessorySetupKit picker, scoped to the X3's sync
    /// service so it lists only readers that are advertising and in a
    /// bonding-ready state. Bonding itself happens automatically once the
    /// picker's selection triggers `didConnect` on an encrypted link — the
    /// reader initiates it, and iOS shows its native pairing sheet.
    ///
    /// The picker refuses to appear while the process holds any live
    /// CBManager (ASErrorDomain code 550, "CBManagers active with global
    /// permissions"), so the central is released for the picker's lifetime
    /// and rebuilt afterwards on every exit path.
    private func showAccessoryPicker() {
        let descriptor = ASDiscoveryDescriptor()
        descriptor.bluetoothServiceUUID = XteinkSyncProtocol.service
        let item = ASPickerDisplayItem(
            name: L10n.string("Settings_xteink_pickerAccessoryName"),
            productImage: UIImage(systemName: "book.closed") ?? UIImage(),
            descriptor: descriptor)
        Task { @MainActor [weak self] in
            guard let self else { return }
            XteinkBLECentral.shared.setPairingMode(true)
            await XteinkBLECentral.shared.releaseForAccessoryPicker()
            do {
                try await self.accessorySession.showPicker(for: [item])
                // A selection continues in `handleAccessoryEvent`; a
                // cancelled picker reports nothing at all. Rebuild the
                // central either way (idempotent), and stand pairing mode
                // down if no selection arrives shortly after dismissal.
                XteinkBLECentral.shared.rebuildAfterAccessoryPicker()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, !self.pairingInFlight else { return }
                    XteinkBLECentral.shared.setPairingMode(false)
                }
            } catch {
                XteinkBLECentral.shared.rebuildAfterAccessoryPicker()
                XteinkBLECentral.shared.setPairingMode(false)
                SharedDiagnosticLog.record("Accessory picker failed: \(error)", category: "xteink")
                self.presentInfoAlert(
                    title: L10n.string("Settings_xteink_pairFailedTitle"), message: "\(error)")
            }
        }
    }

    /// The picker only reports a selection through this event — there is no
    /// return value from `showPicker`. Pairing starts the moment the system
    /// hands back an accessory with a resolved Bluetooth identifier.
    private func handleAccessoryEvent(_ event: ASAccessoryEvent) {
        guard event.eventType == .accessoryAdded,
              let peripheralIdentifier = event.accessory?.bluetoothIdentifier
        else { return }
        beginPairing(peripheralIdentifier: peripheralIdentifier)
    }

    private func beginPairing(peripheralIdentifier: UUID) {
        pairingInFlight = true
        // The central was released for the picker; the connect below parks
        // until the rebuilt manager reaches poweredOn.
        XteinkBLECentral.shared.rebuildAfterAccessoryPicker()
        XteinkBLECentral.shared.connect(toPeripheralIdentifier: peripheralIdentifier)
        Task { @MainActor in
            let spinner = UIAlertController(
                title: L10n.string("Settings_xteink_pairingProgressTitle"),
                message: nil, preferredStyle: .alert)
            var finished = false
            // The picker sheet is still animating out when this Task starts;
            // present the spinner once the presenter frees up, and only
            // while the pairing is still in flight.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, !finished, self.presentedViewController == nil else { return }
                self.present(spinner, animated: true)
            }
            func settle(title: String, message: String) {
                finished = true
                self.pairingInFlight = false
                XteinkBLECentral.shared.setPairingMode(false)
                if spinner.presentingViewController != nil { spinner.dismiss(animated: true) }
                self.presentInfoAlert(title: title, message: message)
            }
            do {
                try await Self.waitForRendezvous()
                // The reader accepts a pairing hello only once the link is
                // encrypted, and encryption waits for the user to accept the
                // iOS bonding sheet. Retry across that window instead of
                // failing while the sheet is still on screen.
                try await Self.pairAllowingBondingTime(pairSecret: Self.pairSecret())
                // Close the reader's rendezvous window now: it flips its
                // popup to "Luna paired" the moment no_work lands, instead
                // of holding the popup until an idle timeout. Then drop the
                // link — a parked connection would otherwise ride into the
                // reader's BLE teardown.
                try? await XteinkBLECentral.shared.reportNoWork()
                XteinkBLECentral.shared.endRendezvous()
                XteinkSendSettings.isEnabled = true
                self.tableView.reloadData()
                settle(title: L10n.string("Settings_xteink_pairSuccessTitle"), message: L10n.string("Settings_xteink_pairSuccessMessage"))
            } catch {
                XteinkBLECentral.shared.endRendezvous()
                settle(title: L10n.string("Settings_xteink_pairFailedTitle"), message: "\(error)")
            }
        }
    }

    /// Retries the pairing hello while the user answers the iOS bonding
    /// sheet: the reader answers `pairing_failed` until the link encrypts,
    /// and the sheet has no completion callback Luna can await.
    private static func pairAllowingBondingTime(
        pairSecret: String, attempts: Int = 6, retryPause: TimeInterval = 3
    ) async throws {
        for attempt in 1...attempts {
            do {
                try await XteinkBLECentral.shared.pair(pairSecret: pairSecret)
                return
            } catch XteinkSyncError.protocolError(let reason) where reason == "pairing_failed" && attempt < attempts {
                try await Task.sleep(nanoseconds: UInt64(retryPause * 1_000_000_000))
            }
        }
    }

    /// The scan begun when the prompt appeared needs a few seconds to find and
    /// connect the reader. Waiting here turns "instant unavailable" into a
    /// pairing attempt, and into a visible timeout error when no reader is up.
    private static func waitForRendezvous(timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !XteinkBLECentral.shared.isRendezvousActive {
            guard Date() < deadline else { throw XteinkSyncError.unavailable }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
    }

    private static func pairSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func presentUnpairConfirmation() {
        let alert = UIAlertController(
            title: L10n.string("Settings_xteink_unpairTitle"),
            message: L10n.string("Settings_xteink_unpairMessage"), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("Settings_xteink_unpairConfirm"), style: .destructive) {
            [weak self] _ in
            self?.unpair()
        })
        present(alert, animated: true)
    }

    private func unpair() {
        XteinkBLECentral.shared.forgetPairing()
        XteinkSendSettings.isEnabled = false
        tableView.reloadData()
        // Also drop the AccessorySetupKit authorization: a lingering entry
        // would keep the accessory "already set up" and confuse the next
        // pairing's picker.
        Task { @MainActor [weak self] in
            guard let self else { return }
            for accessory in self.accessorySession.accessories {
                try? await self.accessorySession.removeAccessory(accessory)
            }
        }
    }
}
