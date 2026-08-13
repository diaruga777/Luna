//
//  ReaderSettingsScreens.swift
//  Luna
//
//  Article-kind settings subpages (extracted from `SettingsViewController` so
//  the top-level menu stays kind-neutral). Compiled only into article-handling
//  app targets (Reader + the central Luna app); their `KindWiring` variants
//  list these screens through `settingsCategories()`.
//

import LunaReadingListUI
import LunaReaderUI
import LunaDesignSystem
import LunaStorage
import LunaModels
import UIKit

// MARK: - Reader

/// RSVP, typography, highlight, and saves link-preload preferences.
final class ReaderSettingsScreen: NavHeaderTableController {
    private enum Section: Int, CaseIterable { case reader, preload }
    private enum Row: Int, CaseIterable { case speed, rsvpMode, font, textSize, accentColor }
    private let wpmLabel = UILabel()

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = L10n.string("Common_reader")
        super.viewDidLoad()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Section(rawValue: section) == .reader ? Row.allCases.count : 2
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .reader: return L10n.string("Settings_reader_speedAndAppearanceSectionHeader")
        case .preload: return L10n.string("Settings_reader_preloadSectionHeader")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard Section(rawValue: section) == .preload else { return nil }
        return L10n.string("Settings_reader_preloadFooter")
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        cell.selectionStyle = .none

        if Section(rawValue: indexPath.section) == .preload {
            if indexPath.row == 0 {
                content.text = L10n.string("Settings_reader_preloadWiFiOnlyLabel")
                cell.accessoryView = makeToggle(
                    isOn: ReaderSettings.preloadWiFiOnly,
                    action: #selector(preloadWiFiOnlyToggled(_:)))
            } else {
                content.text = L10n.string("Settings_reader_preloadDepthLabel")
                content.secondaryText = "\(ReaderSettings.preloadDepth)"
                let stepper = UIStepper()
                stepper.minimumValue = Double(ReaderSettings.preloadDepthRange.lowerBound)
                stepper.maximumValue = Double(ReaderSettings.preloadDepthRange.upperBound)
                stepper.value = Double(ReaderSettings.preloadDepth)
                stepper.addTarget(
                    self, action: #selector(preloadDepthChanged(_:)), for: .valueChanged)
                cell.accessoryView = stepper
            }
            cell.contentConfiguration = content
            return cell
        }

        switch Row(rawValue: indexPath.row)! {
        case .speed:
            wpmLabel.text = L10n.string("Common_wpm", Int(ReaderSettings.baseWPM))
            wpmLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
            wpmLabel.textColor = LunaColors.secondaryText
            wpmLabel.sizeToFit()
            let slider = UISlider()
            slider.minimumValue = 100
            slider.maximumValue = 900
            slider.value = Float(ReaderSettings.baseWPM)
            slider.addTarget(self, action: #selector(wpmChanged(_:)), for: .valueChanged)
            slider.translatesAutoresizingMaskIntoConstraints = false
            wpmLabel.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(slider)
            cell.contentView.addSubview(wpmLabel)
            NSLayoutConstraint.activate([
                slider.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                slider.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
                wpmLabel.leadingAnchor.constraint(equalTo: slider.trailingAnchor, constant: 12),
                wpmLabel.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                wpmLabel.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
                wpmLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 70),
                cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            ])
            return cell
        case .rsvpMode:
            // Words vs Phrases for the RSVP speed reader — moved here out of the
            // reader itself (`RSVPViewController` reads `ReaderSettings.rsvpMode`
            // when it opens). Default is Words.
            content.text = L10n.string("Settings_reader_speedReaderLabel")
            let control = UISegmentedControl(items: [L10n.string("Settings_reader_rsvpModeWordsOption"), L10n.string("Settings_reader_rsvpModePhrasesOption")])
            control.selectedSegmentIndex = ReaderSettings.rsvpMode == .phrases ? 1 : 0
            control.addTarget(self, action: #selector(rsvpModeChanged(_:)), for: .valueChanged)
            cell.accessoryView = control
        case .font:
            content.text = L10n.string("Settings_reader_fontLabel")
            cell.accessoryView = makeFontButton()
        case .textSize:
            content.text = L10n.string("Settings_reader_textSizeLabel")
            let control = UISegmentedControl(items: [
                L10n.string("Settings_reader_textSizeOptionS"),
                L10n.string("Settings_reader_textSizeOptionM"),
                L10n.string("Settings_reader_textSizeOptionL"),
                L10n.string("Settings_reader_textSizeOptionXL"),
            ])
            let scales: [Double] = [0.85, 1.0, 1.15, 1.3]
            control.selectedSegmentIndex = scales.firstIndex(of: ReaderSettings.fontScale) ?? 1
            control.addTarget(self, action: #selector(textSizeChanged(_:)), for: .valueChanged)
            cell.accessoryView = control
        case .accentColor:
            content.text = L10n.string("Settings_reader_highlightColorLabel")
            cell.accessoryView = makeAccentButton()
        }
        cell.contentConfiguration = content
        return cell
    }

    /// A pull-down button choosing the reader typeface. The button title
    /// renders in the selected font, as a small live preview.
    private func makeFontButton() -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        updateFontButton(button)
        button.sizeToFit()
        return button
    }

    private func updateFontButton(_ button: UIButton) {
        let current = ReaderSettings.font
        button.setTitle(current.displayName, for: .normal)
        button.titleLabel?.font = current.font(size: 17, weight: .regular)
        button.menu = UIMenu(children: ReaderFont.allCases.map { font in
            UIAction(
                title: font.displayName,
                state: font == current ? .on : .off
            ) { [weak self, weak button] _ in
                ReaderSettings.font = font
                if let button {
                    self?.updateFontButton(button)
                    button.sizeToFit()
                }
            }
        })
    }

    /// A pull-down button choosing the reader highlight color, with a swatch.
    private func makeAccentButton() -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        updateAccentButton(button)
        button.sizeToFit()
        return button
    }

    private func swatch(for accent: ReaderAccent) -> UIImage? {
        UIImage(systemName: "circle.fill")?
            .withTintColor(accent.color, renderingMode: .alwaysOriginal)
    }

    private func updateAccentButton(_ button: UIButton) {
        let current = ReaderSettings.accent
        button.setTitle(current.displayName, for: .normal)
        button.setImage(swatch(for: current), for: .normal)
        button.configuration = nil
        button.menu = UIMenu(children: ReaderAccent.allCases.map { accent in
            UIAction(
                title: accent.displayName, image: swatch(for: accent),
                state: accent == current ? .on : .off
            ) { [weak self, weak button] _ in
                ReaderSettings.accent = accent
                if let button {
                    self?.updateAccentButton(button)
                    button.sizeToFit()
                }
            }
        })
    }

    @objc private func wpmChanged(_ slider: UISlider) {
        let rounded = Double((Int(slider.value) / 10) * 10)
        ReaderSettings.baseWPM = rounded
        wpmLabel.text = L10n.string("Common_wpm", Int(rounded))
    }

    @objc private func rsvpModeChanged(_ control: UISegmentedControl) {
        ReaderSettings.rsvpMode = control.selectedSegmentIndex == 1 ? .phrases : .words
    }

    @objc private func textSizeChanged(_ control: UISegmentedControl) {
        let scales: [Double] = [0.85, 1.0, 1.15, 1.3]
        ReaderSettings.fontScale = scales[max(0, min(control.selectedSegmentIndex, scales.count - 1))]
    }

    @objc private func preloadWiFiOnlyToggled(_ toggle: UISwitch) {
        ReaderSettings.preloadWiFiOnly = toggle.isOn
        // Turning the restriction off lets any trees deferred while off
        // Wi-Fi proceed immediately over cellular.
        if !toggle.isOn { PreloadCoordinator.shared.resumeIncomplete() }
    }

    @objc private func preloadDepthChanged(_ stepper: UIStepper) {
        ReaderSettings.preloadDepth = Int(stepper.value)
        // Refresh the detail number in place — reloadRows would rebuild the stepper
        // mid-touch and break press-and-hold autorepeat.
        let ip = IndexPath(row: 1, section: Section.preload.rawValue)
        if let cell = tableView.cellForRow(at: ip) {
            var content = cell.contentConfiguration as? UIListContentConfiguration
                ?? cell.defaultContentConfiguration()
            content.secondaryText = "\(ReaderSettings.preloadDepth)"
            cell.contentConfiguration = content
        }
        // Picking up a higher depth resumes preloading for existing saves.
        PreloadCoordinator.shared.resumeIncomplete()
    }
}
