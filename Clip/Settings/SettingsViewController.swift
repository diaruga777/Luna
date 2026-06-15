//
//  SettingsViewController.swift
//  Clip
//

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
        present(alert, animated: true)
    }
}

/// Top-level settings: a system-Settings-style menu that drills into a focused
/// subpage per category.
final class SettingsViewController: UITableViewController {

    private struct Category {
        let title: String
        let symbol: String
        let make: () -> UIViewController
    }

    private let categories: [Category] = [
        Category(title: "Reader", symbol: "textformat.size") { ReaderSettingsScreen() },
        Category(title: "Reading List", symbol: "list.bullet") { ReadingListSettingsScreen() },
        Category(title: "Eye Tracking", symbol: "eye") { EyeTrackingSettingsScreen() },
        Category(title: "Send to Kindle", symbol: "paperplane") { KindleSettingsScreen() },
        Category(title: "YouTube", symbol: "play.rectangle") { YouTubeSettingsScreen() },
        Category(title: "Shortcut & Safari", symbol: "safari") { ShortcutSettingsScreen() },
        Category(title: "Diagnostics", symbol: "ladybug") { DiagnosticsViewController() },
    ]

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        navigationItem.largeTitleDisplayMode = .never
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        categories.count
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let category = categories[indexPath.row]
        var content = cell.defaultContentConfiguration()
        content.text = category.title
        content.image = UIImage(systemName: category.symbol)
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        navigationController?.pushViewController(categories[indexPath.row].make(), animated: true)
    }
}

// MARK: - Reader

/// RSVP speed, serif toggle, and text size.
final class ReaderSettingsScreen: UITableViewController {
    private enum Row: Int, CaseIterable { case speed, serif, textSize }
    private let wpmLabel = UILabel()

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Reader"
        navigationItem.largeTitleDisplayMode = .never
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        "RSVP Speed & Appearance"
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
        }
        cell.contentConfiguration = content
        return cell
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
final class ReadingListSettingsScreen: UITableViewController {
    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Reading List"
        navigationItem.largeTitleDisplayMode = .never
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 2 }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Show an estimated reading time and your progress on each article."
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        cell.selectionStyle = .none
        if indexPath.row == 0 {
            content.text = "Reading Time"
            cell.accessoryView = makeToggle(
                isOn: ReaderSettings.showReadingTime, action: #selector(readingTimeToggled(_:)))
        } else {
            content.text = "Reading Progress"
            cell.accessoryView = makeToggle(
                isOn: ReaderSettings.showReadingProgress, action: #selector(progressToggled(_:)))
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
}

// MARK: - Eye Tracking

final class EyeTrackingSettingsScreen: UITableViewController {
    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Eye Tracking"
        navigationItem.largeTitleDisplayMode = .never
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { 1 }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Uses the front camera (on supported devices) to estimate the last word you read, so audio and RSVP can start there. Turning this off clears all stored estimates."
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = "Track Reading Position"
        cell.contentConfiguration = content
        cell.accessoryView = makeToggle(
            isOn: ReaderSettings.eyeTrackingEnabled, action: #selector(eyeTrackingToggled(_:)))
        cell.selectionStyle = .none
        return cell
    }

    @objc private func eyeTrackingToggled(_ toggle: UISwitch) {
        ReaderSettings.eyeTrackingEnabled = toggle.isOn
        if !toggle.isOn { ReadingListStore.shared.clearAllEyeTracking() }
    }
}

// MARK: - Shortcut & Safari

final class ShortcutSettingsScreen: UITableViewController {
    private enum Row: Int, CaseIterable { case install, openShortcuts, refreshStatus }
    private var safariStatusText = ""

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Shortcut & Safari"
        navigationItem.largeTitleDisplayMode = .never
        refreshSafariStatus()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        "Save the Safari page you're reading with one press of the Action Button: enable the Clip Safari extension (Settings → Apps → Safari → Extensions), install the shortcut, then pick \"Clip Safari Page\" in Settings → Action Button.\n\n\(safariStatusText)"
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
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
            content.text = "Refresh Extension Status"
            content.image = UIImage(systemName: "arrow.clockwise")
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Row(rawValue: indexPath.row)! {
        case .install:
            installShortcut(from: tableView.cellForRow(at: indexPath) ?? view)
        case .openShortcuts:
            if let url = URL(string: "shortcuts://") { UIApplication.shared.open(url) }
        case .refreshStatus:
            refreshSafariStatus()
            tableView.reloadData()
        }
    }

    /// Shares the bundled signed shortcut to the Shortcuts app (one-tap import;
    /// `shortcuts://import-workflow` rejects local file URLs).
    private func installShortcut(from sourceView: UIView) {
        guard let bundled = Bundle.main.url(
            forResource: "Clip Safari Page", withExtension: "shortcut")
        else { return }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Clip Safari Page.shortcut")
        try? FileManager.default.removeItem(at: tmp)
        try? FileManager.default.copyItem(at: bundled, to: tmp)
        let activity = UIActivityViewController(activityItems: [tmp], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = sourceView
        present(activity, animated: true)
    }

    private func refreshSafariStatus() {
        if let url = SafariURLStore.lastURL {
            let when = SafariURLStore.lastDate.map {
                RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: Date())
            } ?? "unknown time"
            safariStatusText = "Last tracked Safari URL (\(when)): \(url)"
        } else {
            safariStatusText = "No Safari URL tracked yet. Enable the Clip extension in Safari (Settings → Apps → Safari → Extensions) and browse to a page."
        }
    }
}
