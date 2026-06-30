//
//  AutoDownloadSettingsScreen.swift
//  Clip
//

import ClipReadingListUI
import ClipMediaDownload
import ClipDesignSystem
import UIKit

/// Per-platform toggles to auto-save a saved post's media to the photo library.
/// Turning a toggle on first requires Photos add permission — flipping it prompts,
/// and reverts if access is denied.
final class AutoDownloadSettingsScreen: NavHeaderTableController {

    private let platforms = AutoDownloadSettings.platforms
    private let saver = PhotoLibrarySaver()

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = "Auto-Download Media"
        super.viewDidLoad()
    }

    // Section 0: the master "Auto-download media" switch (the action extension's
    // inline preview reads this). Section 1: the per-platform auto-save-to-Photos
    // toggles used by the main app's ingest funnel.
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : platforms.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? "Auto-Save to Photos by Platform" : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 {
            return "When on, the action extension downloads a saved post's media automatically and shows it inline. Turn off to download manually with a button."
        }
        return "Auto-download media from saved posts from that platform and save straight to your photo library. Requires Photos access. Quartz never reads or edits your photos."
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        if indexPath.section == 0 { return autoDownloadCell() }
        let platform = platforms[indexPath.row]
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
        toggle.tag = indexPath.row
        toggle.addTarget(self, action: #selector(toggled(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    /// The master "Auto-download media" row. No Photos prompt here — downloading
    /// inline doesn't touch Photos; the prompt happens when the user saves.
    private func autoDownloadCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.text = "Auto-download media"
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

    @objc private func toggled(_ sender: UISwitch) {
        let platform = platforms[sender.tag]
        guard sender.isOn else {
            AutoDownloadSettings.setEnabled(false, for: platform)
            return
        }
        // Enabling needs Photos access — prompt, and revert if denied.
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
            title: "Photos Access Needed",
            message: "Allow photo library access in Settings to auto-download media.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        present(alert, animated: true)
    }
}
