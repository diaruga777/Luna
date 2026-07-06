//
//  ExperimentalSettingsScreen.swift
//  Luna
//

import LunaReadingListUI
import LunaReaderUI
import LunaDesignSystem
import LunaTransitions
import UIKit

final class ExperimentalSettingsScreen: NavHeaderTableController {

    private enum Section: Int, CaseIterable {
        case paywallStrategies, archiveOverlay
    }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = "Experimental"
        super.viewDidLoad()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .paywallStrategies: return 1
        case .archiveOverlay: return 1
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .paywallStrategies: return "Extra Paywall Unlock Strategies"
        case .archiveOverlay: return "Archive Reader Cover"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .paywallStrategies:
            return "Off by default. When on, Luna tries to unlock a paywalled article on-device — keeping cookies, blocking the site's metering scripts, spoofing the referrer a site unlocks for, and cleaning the page — before falling back to the archive reader. This unlocks many soft paywalls the archive can't, but adds a few seconds before the fallback. Turn it off to go straight to the archive reader."
        case .archiveOverlay:
            return "Opacity of overlay while we work to unlock web articles"
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        switch Section(rawValue: indexPath.section)! {
        case .paywallStrategies:
            return paywallStrategiesCell()
        case .archiveOverlay:
            return overlayAlphaCell()
        }
    }

    /// A toggle that enables the on-device (non-archive) paywall-bypass strategies.
    private func paywallStrategiesCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.text = "Unlock Paywalls On-Device"
        cell.contentConfiguration = content
        cell.accessoryView = makeToggle(
            isOn: ReaderSettings.nonArchiveBypassEnabled,
            action: #selector(nonArchiveBypassToggled(_:)))
        return cell
    }

    @objc private func nonArchiveBypassToggled(_ toggle: UISwitch) {
        ReaderSettings.nonArchiveBypassEnabled = toggle.isOn
    }

    /// A slider for the archive-reader cover opacity (20%–99%, default 99%).
    private func overlayAlphaCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none

        let slider = UISlider()
        slider.minimumValue = Float(ReaderSettings.archiveOverlayAlphaRange.lowerBound)
        slider.maximumValue = Float(ReaderSettings.archiveOverlayAlphaRange.upperBound)
        slider.value = Float(ReaderSettings.archiveOverlayAlpha)
        slider.addTarget(self, action: #selector(overlayAlphaChanged(_:)), for: .valueChanged)

        let endLabels = UIStackView(arrangedSubviews: [endCaption("20%"), UIView(), endCaption("99%")])
        endLabels.axis = .horizontal
        endLabels.distribution = .fill

        let stack = UIStackView(arrangedSubviews: [slider, endLabels])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -10),
        ])
        return cell
    }

    @objc private func overlayAlphaChanged(_ sender: UISlider) {
        ReaderSettings.archiveOverlayAlpha = Double(sender.value)
    }

    private func endCaption(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabel
        return label
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }
}
