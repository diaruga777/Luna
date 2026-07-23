//
//  RescueSettingsScreen.swift
//  Luna
//

import LunaDesignSystem
import LunaStorage
import UIKit

/// The URL-rescue consent toggle (`claudedocs/url-rescue.md`): when a page can't
/// be saved normally, Luna asks Apple Intelligence (on-device, or Private Cloud
/// Compute when available) to recover it. Clone of `AudioSettingsScreen`'s
/// single-toggle-with-privacy-footer shape.
final class RescueSettingsScreen: NavHeaderTableController {

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = "Failed Saves"
        super.viewDidLoad()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "When a page can't be saved normally, Luna automatically asks Apple Intelligence to "
            + "recover it — turning it into a readable article, a price tracker, or a media "
            + "download. Processing happens on your iPhone or in Apple's Private Cloud Compute, "
            + "which is designed so that no one — not even Apple — can access your data; nothing "
            + "is ever sent to Luna. With this off, you can still rescue any individual failed "
            + "save by tapping it."
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = "Rescue Failed Saves"
        content.secondaryText = "Apple Intelligence"
        content.secondaryTextProperties.color = LunaColors.secondaryText
        content.secondaryTextProperties.font = .systemFont(ofSize: 12)
        cell.selectionStyle = .none
        cell.accessoryView = makeToggle(
            isOn: RescueSettings.isAutoRescueEnabled, action: #selector(rescueToggled(_:)))
        cell.contentConfiguration = content
        return cell
    }

    @objc private func rescueToggled(_ toggle: UISwitch) {
        RescueSettings.isAutoRescueEnabled = toggle.isOn
    }
}
