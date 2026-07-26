//
//  DownloadsSettingsScreen.swift
//  Luna
//

import LunaMediaDownload
import LunaDesignSystem
import UIKit
import LunaModels

/// Shared media download and retention controls for Luna and Luna Downloader.
final class DownloadsSettingsScreen: NavHeaderTableController {

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = L10n.string("Downloads")
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
            return L10n.string("Choose whether saved media downloads on its own. On Wi-Fi Only defers a download that starts on cellular until Wi-Fi is available. Downloads you start by tapping or long-pressing an item always begin right away.")
        case .storage:
            return L10n.string("Save to Photos puts every finished download in your photo library and keeps it there. Otherwise all downloads stay in Luna and are deleted automatically once they reach the age you pick.")
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
            title: L10n.string("Download Automatically"), symbol: "arrow.down.circle",
            identifier: "downloadAutomaticallyPicker", value: current.displayName, menu: menu)
    }

    private func storageCell() -> UITableViewCell {
        let current = MediaStorageSettings.option
        let menu = UIMenu(children: MediaStorageOption.allCases.map { option in
            UIAction(title: option.displayName, state: option == current ? .on : .off) { [weak self] _ in
                MediaStorageSettings.option = option
                self?.reload(.storage)
            }
        })
        return pickerCell(
            title: L10n.string("Storage"), symbol: "internaldrive",
            identifier: "storagePicker", value: current.displayName, menu: menu)
    }

    /// A row whose accessory is a pull-down menu button showing the current choice.
    private func pickerCell(
        title: String, symbol: String, identifier: String, value: String, menu: UIMenu
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
        cell.accessoryView = button
        return cell
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
