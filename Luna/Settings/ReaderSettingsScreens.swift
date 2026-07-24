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

/// RSVP speed, typeface, text size, and highlight color.
final class ReaderSettingsScreen: NavHeaderTableController {
    private enum Row: Int, CaseIterable { case speed, font, textSize, accentColor }
    private let wpmLabel = UILabel()

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = "Reader"
        super.viewDidLoad()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "Speed Reading & Appearance"
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        cell.selectionStyle = .none

        switch Row(rawValue: indexPath.row)! {
        case .speed:
            wpmLabel.text = "\(Int(ReaderSettings.baseWPM)) wpm"
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
        case .font:
            content.text = "Font"
            cell.accessoryView = makeFontButton()
        case .textSize:
            content.text = "Text Size"
            let control = UISegmentedControl(items: ["S", "M", "L", "XL"])
            let scales: [Double] = [0.85, 1.0, 1.15, 1.3]
            control.selectedSegmentIndex = scales.firstIndex(of: ReaderSettings.fontScale) ?? 1
            control.addTarget(self, action: #selector(textSizeChanged(_:)), for: .valueChanged)
            cell.accessoryView = control
        case .accentColor:
            content.text = "Highlight Color"
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
        wpmLabel.text = "\(Int(rounded)) wpm"
    }

    @objc private func textSizeChanged(_ control: UISegmentedControl) {
        let scales: [Double] = [0.85, 1.0, 1.15, 1.3]
        ReaderSettings.fontScale = scales[max(0, min(control.selectedSegmentIndex, scales.count - 1))]
    }
}

// MARK: - Reading List

/// Reading-time and progress display toggles.
final class ReadingListSettingsScreen: NavHeaderTableController {
    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = "Reading List"
        super.viewDidLoad()
    }

    private enum Section: Int, CaseIterable { case display, preload }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 2 }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section) == .preload ? "Preload Links" : nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .display:
            return "Show an estimated reading time and your progress on each article."
        case .preload:
            return "Preload the content of links in a saved article (and links on those "
                + "pages, up to this depth) in the background, so tapping a link opens "
                + "instantly. 0 turns preloading off. Preloading uses any network by "
                + "default; turn on Wi-Fi Only to restrict it to Wi-Fi."
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        cell.selectionStyle = .none
        switch Section(rawValue: indexPath.section)! {
        case .display where indexPath.row == 0:
            content.text = "Reading Time"
            cell.accessoryView = makeToggle(
                isOn: ReaderSettings.showReadingTime, action: #selector(readingTimeToggled(_:)))
        case .display:
            content.text = "Reading Progress"
            cell.accessoryView = makeToggle(
                isOn: ReaderSettings.showReadingProgress, action: #selector(progressToggled(_:)))
        case .preload where indexPath.row == 0:
            content.text = "Wi-Fi Only"
            cell.accessoryView = makeToggle(
                isOn: ReaderSettings.preloadWiFiOnly, action: #selector(preloadWiFiOnlyToggled(_:)))
        case .preload:
            content.text = "Preload Depth"
            // The current depth shows as the value1 detail text (left of the stepper),
            // so it's always visible; the stepper is the tappable accessory.
            content.secondaryText = "\(ReaderSettings.preloadDepth)"
            let stepper = UIStepper()
            stepper.minimumValue = Double(ReaderSettings.preloadDepthRange.lowerBound)
            stepper.maximumValue = Double(ReaderSettings.preloadDepthRange.upperBound)
            stepper.value = Double(ReaderSettings.preloadDepth)
            stepper.addTarget(self, action: #selector(preloadDepthChanged(_:)), for: .valueChanged)
            cell.accessoryView = stepper
        }
        cell.contentConfiguration = content
        return cell
    }

    @objc private func readingTimeToggled(_ toggle: UISwitch) {
        ReaderSettings.showReadingTime = toggle.isOn
        NotificationCenter.default.post(name: .readingListChanged, object: nil)
    }

    @objc private func progressToggled(_ toggle: UISwitch) {
        ReaderSettings.showReadingProgress = toggle.isOn
        NotificationCenter.default.post(name: .readingListChanged, object: nil)
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
