//
//  AppearanceSettingsScreen.swift
//  Luna
//

import LunaDesignSystem
import UIKit
import LunaModels

/// App-wide interface style and the Reader-only Lunar Eclipse experiment.
final class AppearanceSettingsScreen: NavHeaderTableController {

    private enum Section: Int, CaseIterable { case theme, motion }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = L10n.string("Appearance")
        super.viewDidLoad()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        AppSurfaceConfig.current == .reader ? Section.allCases.count : 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .theme: return L10n.string("Theme")
        case .motion: return L10n.string("Motion")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .theme: return nil
        case .motion:
            return L10n.string("Lunar Eclipse is an opt-in transition used only when Luna Reader opens or closes an article. Reduce Motion disables it automatically.")
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .theme:
            return themeCell()
        case .motion:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            var content = cell.defaultContentConfiguration()
            content.text = L10n.string("Lunar Eclipse Transition")
            cell.contentConfiguration = content
            cell.accessoryView = makeToggle(
                isOn: AppearanceSettings.lunarEclipseReaderTransitionEnabled,
                action: #selector(lunarEclipseTransitionToggled(_:)))
            return cell
        }
    }

    /// A full-width segmented control (System / Light / Dark) — three options don't
    /// fit beside a label, so it fills the cell like the Safari-suggestion control.
    private func themeCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        let control = UISegmentedControl(
            items: AppearanceSettings.InterfaceStyle.allCases.map(\.displayName))
        control.selectedSegmentIndex =
            AppearanceSettings.InterfaceStyle.allCases.firstIndex(of: AppearanceSettings.interfaceStyle) ?? 0
        control.addTarget(self, action: #selector(interfaceStyleChanged(_:)), for: .valueChanged)
        control.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(control)
        // Center at the control's natural height (pinning top+bottom would stretch it).
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            control.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
            control.topAnchor.constraint(greaterThanOrEqualTo: cell.contentView.topAnchor, constant: 8),
            control.bottomAnchor.constraint(lessThanOrEqualTo: cell.contentView.bottomAnchor, constant: -8),
        ])
        return cell
    }

    @objc private func interfaceStyleChanged(_ control: UISegmentedControl) {
        let styles = AppearanceSettings.InterfaceStyle.allCases
        AppearanceSettings.interfaceStyle = styles[max(0, min(control.selectedSegmentIndex, styles.count - 1))]
        // Re-apply live to every connected scene's windows.
        for window in UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows) {
            AppearanceSettings.apply(to: window)
        }
    }

    @objc private func lunarEclipseTransitionToggled(_ toggle: UISwitch) {
        AppearanceSettings.lunarEclipseReaderTransitionEnabled = toggle.isOn
    }
}
