//
//  AutoDownloadSettingsScreen.swift
//  Luna
//

import LunaReadingListUI
import LunaMediaDownload
import LunaDesignSystem
import LunaTransitions
import UIKit

/// Media download and retention controls. Downloader saves supported media into
/// app-owned storage automatically; the retention rows control when those local
/// files are cleaned up.
final class AutoDownloadSettingsScreen: NavHeaderTableController {
    private let platforms = AutoDownloadSettings.platforms
    private let saver = PhotoLibrarySaver()
    private let daysLabel = UILabel()
    private var isDownloader: Bool { AppSurfaceConfig.current == .downloader }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = "Auto-Download Media"
        super.viewDidLoad()
    }

    // Downloader: retention + completion actions + preview switch. Sibling apps:
    // preview switch + the existing per-platform explicit Photos auto-save toggles.
    override func numberOfSections(in tableView: UITableView) -> Int { isDownloader ? 3 : 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        if isDownloader { return section == 0 ? 2 : (section == 1 ? 2 : 1) }
        return section == 0 ? 1 : platforms.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if isDownloader {
            switch section {
            case 0: return "Local Files"
            case 1: return "After Downloading"
            default: return nil
            }
        }
        return section == 1 ? "Auto-Save to Photos by Platform" : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if isDownloader {
            switch section {
            case 0:
                return "Files saved in Luna Downloader are deleted automatically after the selected number of days. Turn retention off to keep files until you delete them."
            case 1:
                return "Photos-backed downloads stay in your photo library. Clipboard copies use the downloaded file, including for videos."
            default:
                return "When on, the action extension downloads a saved post's media automatically and shows it inline. Turn off to download manually with a button."
            }
        } else {
            if section == 0 {
                return "When on, the action extension downloads a saved post's media automatically and shows it inline. Turn off to download manually with a button."
            }
            return "Auto-download media from saved posts from that platform and save straight to your photo library. Requires Photos access. Luna never reads or edits your photos."
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        if !isDownloader {
            return indexPath.section == 0 ? autoDownloadCell() : platformCell(at: indexPath.row)
        }
        switch indexPath.section {
        case 0:
            return indexPath.row == 0 ? retentionDaysCell() : retentionDisabledCell()
        case 1:
            return indexPath.row == 0 ? autoSaveToPhotosCell() : autoCopyToClipboardCell()
        default:
            return autoDownloadCell()
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

    private func retentionDaysCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.text = "Delete After"
        content.image = UIImage(systemName: "calendar.badge.clock")
        cell.contentConfiguration = content

        let stepper = UIStepper()
        stepper.minimumValue = 1
        stepper.maximumValue = 30
        stepper.value = Double(MediaRetentionSettings.retentionDays ?? 7)
        stepper.addTarget(self, action: #selector(retentionDaysChanged(_:)), for: .valueChanged)

        daysLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        daysLabel.textColor = .secondaryLabel
        updateDaysLabel()
        let stack = UIStackView(arrangedSubviews: [daysLabel, stepper])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        cell.accessoryView = stack
        return cell
    }

    private func retentionDisabledCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.text = "Keep Until Deleted"
        content.image = UIImage(systemName: "infinity")
        cell.contentConfiguration = content
        let toggle = UISwitch()
        toggle.isOn = MediaRetentionSettings.retentionDays == nil
        toggle.addTarget(self, action: #selector(retentionDisabledChanged(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    private func autoSaveToPhotosCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.text = "Auto-Save to Photos"
        content.image = UIImage(systemName: "photo.badge.arrow.down")
        cell.contentConfiguration = content
        cell.accessoryView = makeToggle(
            isOn: AutoDownloadSettings.autoSaveDownloadsToPhotos,
            action: #selector(autoSaveToPhotosToggled(_:)))
        return cell
    }

    private func autoCopyToClipboardCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.text = "Copy Downloads to Clipboard"
        content.image = UIImage(systemName: "doc.on.clipboard")
        cell.contentConfiguration = content
        cell.accessoryView = makeToggle(
            isOn: AutoDownloadSettings.autoCopyDownloadsToClipboard,
            action: #selector(autoCopyToClipboardToggled(_:)))
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

    @objc private func autoSaveToPhotosToggled(_ sender: UISwitch) {
        AutoDownloadSettings.autoSaveDownloadsToPhotos = sender.isOn
    }

    @objc private func autoCopyToClipboardToggled(_ sender: UISwitch) {
        AutoDownloadSettings.autoCopyDownloadsToClipboard = sender.isOn
    }

    @objc private func retentionDaysChanged(_ sender: UIStepper) {
        MediaRetentionSettings.retentionDays = Int(sender.value)
        updateDaysLabel()
        tableView.reloadRows(at: [IndexPath(row: 1, section: 0)], with: .none)
    }

    @objc private func retentionDisabledChanged(_ sender: UISwitch) {
        MediaRetentionSettings.retentionDays = sender.isOn ? nil : 7
        tableView.reloadRows(at: [IndexPath(row: 0, section: 0)], with: .none)
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
            title: "Photos Access Needed",
            message: "Allow photo library access in Settings to auto-download media.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }
        })
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        DotMatrixModal.present(alert, from: self)
    }

    private func updateDaysLabel() {
        if let days = MediaRetentionSettings.retentionDays {
            daysLabel.text = "\(days) day\(days == 1 ? "" : "s")"
        } else {
            daysLabel.text = "Off"
        }
        daysLabel.sizeToFit()
    }
}
