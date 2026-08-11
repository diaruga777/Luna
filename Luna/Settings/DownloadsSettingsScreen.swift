//
//  DownloadsSettingsScreen.swift
//  Luna
//

import LunaMediaDownload
import LunaDesignSystem
import Photos
import UIKit
import LunaModels

/// Shared media download and retention controls for Luna and Luna Downloader.
final class DownloadsSettingsScreen: NavHeaderTableController {

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = L10n.string("Common_downloads")
        super.viewDidLoad()
    }

    /// Downloader: the automatic-download policy, then storage (Photos vs. local
    /// files with a deletion clock — the two are mutually exclusive, which is why
    /// they are one row).
    private enum DownloaderSection: Int { case autoDownload, storage }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch DownloaderSection(rawValue: section)! {
        case .autoDownload:
            return L10n.string("Settings_downloads_autoDownloadFooter")
        case .storage:
            return L10n.string("Settings_downloads_storageFooter")
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch DownloaderSection(rawValue: indexPath.section)! {
        case .autoDownload: return autoDownloadPolicyCell()
        case .storage: return storageCell()
        }
    }

    // MARK: - Downloader rows

    private func autoDownloadPolicyCell() -> UITableViewCell {
        let current = AutoDownloadSettings.policy
        let menu = UIMenu(children: AutoDownloadPolicy.allCases.map { policy in
            UIAction(title: policy.displayName, state: policy == current ? .on : .off) { [weak self] _ in
                self?.apply(policy)
            }
        })
        return pickerCell(
            title: L10n.string("Settings_downloads_autoDownloadLabel"), symbol: "arrow.down.circle",
            identifier: "downloadAutomaticallyPicker", value: current.displayName, menu: menu)
    }

    private func storageCell() -> UITableViewCell {
        let current = MediaStorageSettings.option
        let menu = UIMenu(children: MediaStorageOption.allCases.map { option in
            UIAction(title: option.displayName, state: option == current ? .on : .off) { [weak self] _ in
                // `choose`, not `option =`: answering here also retires the util
                // card's inline "Store downloads …" line.
                MediaStorageSettings.choose(option)
                self?.reload(.storage)
            }
        })
        return pickerCell(
            title: L10n.string("Settings_downloads_storageLabel"), symbol: "internaldrive",
            identifier: "storagePicker", value: current.displayName, menu: menu,
            permissionError: Self.needsPhotosPermissionInThisApp)
    }

    /// Whether Photos is the stored destination — possibly answered in the
    /// sibling app that also downloads, since the choice lives in the shared
    /// App Group — while THIS app has never itself been granted Photos access.
    private static var needsPhotosPermissionInThisApp: Bool {
        guard MediaStorageSettings.option == .photos else { return false }
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized, .limited: return false
        default: return true
        }
    }

    /// A row whose accessory is a pull-down menu button showing the current
    /// choice, with an optional red-exclamation permission-error badge ahead
    /// of it.
    private func pickerCell(
        title: String, symbol: String, identifier: String, value: String, menu: UIMenu,
        permissionError: Bool = false
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.text = title
        content.image = UIImage(systemName: symbol)
        cell.contentConfiguration = content

        let button = UIButton(type: .system)
        button.setTitle(value, for: .normal)
        button.accessibilityIdentifier = identifier
        button.accessibilityLabel = title
        button.showsMenuAsPrimaryAction = true
        button.menu = menu
        button.sizeToFit()

        guard permissionError else {
            cell.accessoryView = button
            return cell
        }
        let errorButton = UIButton(type: .system)
        errorButton.setImage(UIImage(systemName: "exclamationmark.circle.fill"), for: .normal)
        errorButton.tintColor = .systemRed
        errorButton.accessibilityIdentifier = "\(identifier).permissionError"
        errorButton.accessibilityLabel = L10n.string(
            "Settings_downloads_storagePermissionErrorLabel")
        errorButton.addAction(UIAction { [weak self] _ in
            self?.presentPhotosPermissionAlert()
        }, for: .touchUpInside)
        errorButton.sizeToFit()
        let stack = UIStackView(arrangedSubviews: [errorButton, button])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        cell.accessoryView = stack
        return cell
    }

    /// Directs the user to this app's own page in system Settings — the only
    /// place a denied Photos permission can now be granted.
    private func presentPhotosPermissionAlert() {
        let alert = UIAlertController(
            title: L10n.string("Onboarding_Util_storagePermissionAlertTitle"),
            message: L10n.string("Onboarding_Util_storagePermissionAlertMessage"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        alert.addAction(UIAlertAction(
            title: L10n.string("Common_openSettings"), style: .default
        ) { _ in
            guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
            UIApplication.shared.open(url)
        })
        present(alert, animated: true)
    }

    private func apply(_ policy: AutoDownloadPolicy) {
        let wasWiFiOnly = AutoDownloadSettings.policy == .wifiOnly
        AutoDownloadSettings.policy = policy
        if wasWiFiOnly, policy == .always {
            // The restriction just lifted — don't make already-deferred items wait
            // for the next opportunistic trigger.
            Task { await LiveMediaDownloadManager.shared.startAllPendingWiFiDownloads() }
        }
        reload(.autoDownload)
    }

    private func reload(_ section: DownloaderSection) {
        tableView.reloadRows(at: [IndexPath(row: 0, section: section.rawValue)], with: .none)
    }

}
