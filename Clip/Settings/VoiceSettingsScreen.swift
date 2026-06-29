//
//  VoiceSettingsScreen.swift
//  Clip
//

import ClipReaderUI
import ClipDesignSystem
import UIKit

/// Informational read-aloud screen. Clip reads aloud with an enhanced Apple voice
/// when one is installed and the built-in system voice otherwise — there is no
/// engine to pick or download. The screen shows whether an enhanced voice is
/// installed and offers a deep-link into iOS Settings to install one.
final class VoiceSettingsScreen: NavHeaderTableController {

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = "Voice"
        super.viewDidLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    // MARK: - Table

    private enum Row: Int, CaseIterable {
        case status
        case install
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Read-Aloud Voice"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Clip reads aloud with enhanced Apple voices when they're installed, "
            + "otherwise the built-in system voice. Install enhanced voices in iOS "
            + "Settings → Accessibility → Spoken Content → Voices."
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()

        switch Row(rawValue: indexPath.row) {
        case .status:
            let installed = VoiceModelStore.isAppleEnhancedInstalled
            content.text = installed ? "Enhanced voices installed" : "Not installed"
            content.image = UIImage(systemName: installed ? "checkmark.circle.fill" : "xmark.circle")
            content.imageProperties.tintColor = installed ? .systemGreen : .secondaryLabel
            cell.selectionStyle = .none
        case .install, .none:
            content.text = "Install Enhanced Voices"
            content.textProperties.color = view.tintColor
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        }

        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Row(rawValue: indexPath.row) == .install else { return }
        VoiceInstallLink.open()
    }
}
