//
//  AutoDownloadSettingsScreen.swift
//  Clip
//

import UIKit

/// Per-platform toggles to auto-save a saved post's media to the photo library.
/// Turning a toggle on first requires Photos add permission — flipping it prompts,
/// and reverts if access is denied.
final class AutoDownloadSettingsScreen: UITableViewController {

    private let platforms = AutoDownloadSettings.platforms
    private let saver = PhotoLibrarySaver()

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Auto-Download Media"
        navigationItem.largeTitleDisplayMode = .never
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        platforms.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Auto-download media from saved posts from that platform and save straight to your photo library. Requires Photos access. Queue never reads or edits your photos."
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
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
