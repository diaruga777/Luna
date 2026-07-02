//
//  AppearanceSettingsScreen.swift
//  Luna
//

import LunaDesignSystem
import UIKit

/// App-wide appearance: the interface-style (System / Light / Dark) override and
/// whether the animated Dot Matrix transitions play.
final class AppearanceSettingsScreen: NavHeaderTableController {

    private enum Section: Int, CaseIterable { case theme, motion }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = "Appearance"
        super.viewDidLoad()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .theme: return "Theme"
        case .motion: return "Motion"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .theme: return nil
        case .motion:
            return "When off, Luna uses the standard system transitions instead of the "
                + "animated ones. They are also disabled automatically when Reduce Motion "
                + "is on in your system accessibility settings."
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
            content.text = "Animated Transitions"
            cell.contentConfiguration = content
            cell.accessoryView = makeToggle(
                isOn: AppearanceSettings.animatedTransitionsEnabled,
                action: #selector(animatedTransitionsToggled(_:)))
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
        // Re-apply live to every connected scene's windows (including any transition
        // cover windows currently on screen).
        for window in UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows) {
            AppearanceSettings.apply(to: window)
        }
    }

    @objc private func animatedTransitionsToggled(_ toggle: UISwitch) {
        AppearanceSettings.animatedTransitionsEnabled = toggle.isOn
    }
}
