//
//  DownloadsSettingsScreen.swift
//  Luna
//

import LunaReadingListUI
import LunaMediaDownload
import LunaDesignSystem
import UIKit
import LunaModels

/// Media download and retention controls. In Downloader this is the whole
/// "Downloads" page: two picker rows — whether media downloads on its own, and
/// where finished downloads live. Sibling apps (the central Luna app) keep the
/// inline auto-download switch plus the per-platform Photos auto-save toggles.
final class DownloadsSettingsScreen: NavHeaderTableController {
    private let platforms = AutoDownloadSettings.platforms
    private let saver = PhotoLibrarySaver()
    private var isDownloader: Bool { AppSurfaceConfig.current == .downloader }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = isDownloader ? L10n.string("Downloads") : L10n.string("Auto-Download Media")
        super.viewDidLoad()
    }

    /// Downloader: the automatic-download policy, then storage (Photos vs. local
    /// files with a deletion clock — the two are mutually exclusive, which is why
    /// they are one row).
    private enum DownloaderSection: Int { case autoDownload, storage }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if isDownloader { return 1 }
        return section == 0 ? 1 : platforms.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard !isDownloader else { return nil }
        return section == 1 ? L10n.string("Auto-Save to Photos by Platform") : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if isDownloader {
            switch DownloaderSection(rawValue: section)! {
            case .autoDownload:
                return L10n.string("Choose whether saved media downloads on its own. On Wi-Fi Only defers a download that starts on cellular until Wi-Fi is available. Downloads you start by tapping or long-pressing an item always begin right away.")
            case .storage:
                return L10n.string("Save to Photos puts finished downloads in your photo library and keeps them there. Otherwise downloads stay in Luna and are deleted automatically once they reach the age you pick.")
            }
        }
        if section == 0 {
            return L10n.string("When on, the action extension downloads a saved post's media automatically and shows it inline. Turn off to download manually with a button.")
        }
        return L10n.string("Auto-download media from saved posts from that platform and save straight to your photo library. Requires Photos access. Luna never reads or edits your photos.")
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        if !isDownloader {
            return indexPath.section == 0 ? autoDownloadCell() : platformCell(at: indexPath.row)
        }
        switch DownloaderSection(rawValue: indexPath.section)! {
        case .autoDownload: return autoDownloadPolicyCell()
        case .storage: return storageCell()
        }
    }

    private func platformCell(at index: Int) -> UITableViewCell {
        let platform = platforms[index]
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.text = platform.displayName
        if let asset = platform.logoAssetName, let logo = UIImage(named: asset) {
            content.image = logo
            content.imageProperties.maximumSize = CGSize(width: 28, height: 28)
        }
        cell.contentConfiguration = content

        let toggle = UISwitch()
        toggle.isOn = AutoDownloadSettings.isEnabled(for: platform)
        toggle.tag = index
        toggle.addTarget(self, action: #selector(platformToggled(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        return cell
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

    // MARK: - Sibling-app rows

    /// The master "Auto-download media" row. No Photos prompt here — downloading
    /// inline doesn't touch Photos; the prompt happens when the user saves.
    private func autoDownloadCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.text = L10n.string("Auto-download media")
        content.image = UIImage(systemName: "arrow.down.circle")
        cell.contentConfiguration = content

        let toggle = UISwitch()
        toggle.isOn = AutoDownloadSettings.autoDownloadMediaInPreview
        toggle.addTarget(self, action: #selector(masterToggled(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    @objc private func masterToggled(_ sender: UISwitch) {
        AutoDownloadSettings.autoDownloadMediaInPreview = sender.isOn
    }

    @objc private func platformToggled(_ sender: UISwitch) {
        let platform = platforms[sender.tag]
        guard sender.isOn else {
            AutoDownloadSettings.setEnabled(false, for: platform)
            return
        }
        Task { @MainActor in
            let granted = await saver.requestAddAuthorization()
            if granted {
                AutoDownloadSettings.setEnabled(true, for: platform)
            } else {
                sender.setOn(false, animated: true)
                AutoDownloadSettings.setEnabled(false, for: platform)
                presentPermissionAlert()
            }
        }
    }

    private func presentPermissionAlert() {
        let alert = UIAlertController(
            title: L10n.string("Photos Access Needed"),
            message: L10n.string("Allow photo library access in Settings to auto-download media."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Open Settings"), style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: L10n.string("OK"), style: .cancel))
        present(alert, animated: true)
    }
}
