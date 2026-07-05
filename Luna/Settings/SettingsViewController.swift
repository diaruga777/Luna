//
//  SettingsViewController.swift
//  Luna
//

import LunaReadingListUI
import LunaSocialUI
import LunaReadingList
import LunaDesignSystem
import LunaStorage
import LunaModels
import LunaTransitions
import UIKit

/// Shared helpers for the settings subpages.
extension UITableViewController {
    func makeToggle(isOn: Bool, action: Selector) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addTarget(self, action: action, for: .valueChanged)
        return toggle
    }

    func presentInfoAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        DotMatrixModal.present(alert, from: self)
    }
}

/// Top-level settings: a system-Settings-style menu that drills into a focused
/// subpage per category.
final class SettingsViewController: NavHeaderTableController {

    private struct Category {
        let title: String
        let symbol: String
        let make: () -> UIViewController
    }

    private let categories: [Category] = [
        Category(title: "Reader", symbol: "textformat.size") { ReaderSettingsScreen() },
        Category(title: "Voice", symbol: "speaker.wave.2") { VoiceSettingsScreen() },
        Category(title: "Reading List", symbol: "list.bullet") { ReadingListSettingsScreen() },
        Category(title: "Email & Sending", symbol: "envelope") { EmailAndKindleSettingsScreen() },
        Category(title: "Music & Podcasts", symbol: "music.note") { MediaProviderSettingsScreen() },
        Category(title: "Auto-Download Media", symbol: "photo.badge.arrow.down") { AutoDownloadSettingsScreen() },
        Category(title: "Shortcut & Safari", symbol: "safari") { ShortcutSettingsScreen() },
        Category(title: "Appearance", symbol: "circle.lefthalf.filled") { AppearanceSettingsScreen() },
        Category(title: "Experimental", symbol: "flask") { ExperimentalSettingsScreen() },
        Category(title: "Diagnostics", symbol: "ladybug") { DiagnosticsViewController() },
    ]

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = "Settings"
        super.viewDidLoad()
    }

    /// Section 1 holds a single "Replay Setup" action (presented modally), kept
    /// out of the pushed `categories` list.
    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? categories.count : 1
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        if indexPath.section == 0 {
            let category = categories[indexPath.row]
            content.text = category.title
            content.image = UIImage(systemName: category.symbol)
            cell.accessoryType = .disclosureIndicator
        } else {
            content.text = "Replay Onboarding"
            content.image = UIImage(systemName: "sparkles")
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 0 {
            navigationController?.pushViewController(categories[indexPath.row].make(), animated: true)
        } else {
            let onboarding = OnboardingFlow.make { [weak self] in
                guard let self else { return }
                DotMatrixModal.dismiss(self)
            }
            onboarding.modalPresentationStyle = .fullScreen
            DotMatrixModal.present(onboarding, from: self)
        }
    }
}

// MARK: - Reader

/// RSVP speed, serif toggle, and text size.
final class ReaderSettingsScreen: NavHeaderTableController {
    private enum Row: Int, CaseIterable { case speed, serif, textSize, accentColor }
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
            wpmLabel.textColor = .secondaryLabel
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
        case .serif:
            content.text = "Serif Font"
            cell.accessoryView = makeToggle(
                isOn: ReaderSettings.useSerifFont, action: #selector(serifToggled(_:)))
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

    @objc private func serifToggled(_ toggle: UISwitch) {
        ReaderSettings.useSerifFont = toggle.isOn
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

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Section(rawValue: section) == .display ? 2 : 1
    }

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
                + "instantly. 0 turns preloading off."
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

    @objc private func preloadDepthChanged(_ stepper: UIStepper) {
        ReaderSettings.preloadDepth = Int(stepper.value)
        // Refresh the detail number in place — reloadRows would rebuild the stepper
        // mid-touch and break press-and-hold autorepeat.
        let ip = IndexPath(row: 0, section: Section.preload.rawValue)
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

// MARK: - Shortcut & Safari

final class ShortcutSettingsScreen: NavHeaderTableController {
    /// Section 0: the Safari extension's "Read in Luna" button visibility.
    /// Section 1: the Action-Button shortcut rows.
    private enum Section: Int, CaseIterable { case suggestionButton, shortcut }
    private enum Row: Int, CaseIterable { case install, openShortcuts, refreshStatus }
    private var safariStatusText = ""

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = "Shortcut & Safari"
        super.viewDidLoad()
        refreshSafariStatus()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { Section.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch Section(rawValue: section)! {
        case .suggestionButton: return 1
        case .shortcut: return Row.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section) == .suggestionButton ? "Read in Luna Button" : "Action Button Shortcut"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .suggestionButton:
            return "When browsing in Safari (with the Luna extension enabled), show a "
                + "\"Read in Luna\" button to open the page in Luna — unlocking paywalled "
                + "articles via the in-app reader. Choose when it appears."
        case .shortcut:
            let base = "Save the Safari webpage by pressing the Action Button: enable the Luna Safari extension (Settings → Apps → Safari → Extensions), install the shortcut, then pick \"\(BundledShortcut.displayName)\" in Settings → Action Button.\n\n\(safariStatusText)"
            if #unavailable(iOS 27.0) {
                return "⚠️ One-press Safari saving requires iOS 27 or later.\n\n" + base
            }
            return base
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        if Section(rawValue: indexPath.section) == .suggestionButton {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            // A full-width segmented control (3 options don't fit beside a label).
            let control = UISegmentedControl(items: SafariSuggestionMode.allCases.map(\.displayName))
            control.selectedSegmentIndex =
                SafariSuggestionMode.allCases.firstIndex(of: SafariSuggestionSettings.mode) ?? 1
            control.addTarget(self, action: #selector(suggestionModeChanged(_:)), for: .valueChanged)
            control.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(control)
            // Center at the control's NATURAL height (pinning top+bottom would
            // stretch it taller than a normal segmented control and look off).
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                control.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                control.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
                control.topAnchor.constraint(greaterThanOrEqualTo: cell.contentView.topAnchor, constant: 8),
                control.bottomAnchor.constraint(lessThanOrEqualTo: cell.contentView.bottomAnchor, constant: -8),
            ])
            return cell
        }

        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.textProperties.color = view.tintColor ?? .systemBlue
        switch Row(rawValue: indexPath.row)! {
        case .install:
            content.text = "Install Shortcut"
            content.image = UIImage(systemName: "square.and.arrow.down")
        case .openShortcuts:
            content.text = "Open Shortcuts"
            content.image = UIImage(systemName: "arrow.up.forward.app")
        case .refreshStatus:
            content.text = "Refresh Last Visited Website"
            content.image = UIImage(systemName: "arrow.clockwise")
        }
        cell.contentConfiguration = content
        return cell
    }

    @objc private func suggestionModeChanged(_ control: UISegmentedControl) {
        let modes = SafariSuggestionMode.allCases
        SafariSuggestionSettings.mode = modes[max(0, min(control.selectedSegmentIndex, modes.count - 1))]
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .shortcut else { return }
        switch Row(rawValue: indexPath.row)! {
        case .install:
            BundledShortcut.presentInstaller(
                from: self, sourceView: tableView.cellForRow(at: indexPath))
        case .openShortcuts:
            if let url = URL(string: "shortcuts://") { UIApplication.shared.open(url) }
        case .refreshStatus:
            refreshSafariStatus()
            tableView.reloadData()
        }
    }


    private func refreshSafariStatus() {
        if let url = SafariURLStore.lastURL {
            let when = SafariURLStore.lastDate.map {
                RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date())
            } ?? "unknown time"
            safariStatusText = "Last visited Safari URL (\(when)): \(url)"
        } else {
            safariStatusText = "No Safari URL tracked yet. Enable the Luna extension in Safari (Settings → Apps → Safari → Extensions) and browse to a page."
        }
    }
}
