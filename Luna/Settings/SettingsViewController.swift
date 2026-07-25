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
import UIKit

/// Shared helpers for the settings subpages.
extension UITableViewController {
    func makeToggle(isOn: Bool, action: Selector) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addTarget(self, action: action, for: .valueChanged)
        return toggle
    }

    func makeToggle(isOn: Bool, onChange: @escaping (Bool) -> Void) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = isOn
        toggle.addAction(UIAction { [weak toggle] _ in onChange(toggle?.isOn ?? false) }, for: .valueChanged)
        return toggle
    }

    func presentInfoAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

/// A row of the top-level settings menu (title + SF Symbol + the subpage it
/// pushes). The kind-specific leading rows come from each app's `KindWiring`
/// variant (`KindWiring.settingsCategories()`); the universal tail is built
/// here.
struct SettingsCategory {
    let title: String
    let symbol: String
    var detail: (() -> String?)? = nil
    let make: () -> UIViewController
}

/// Top-level settings: a system-Settings-style menu that drills into a focused
/// subpage per category.
final class SettingsViewController: NavHeaderTableController {

    private let categories: [SettingsCategory] =
        // Kind rows first (Reader/Audio/Reading List/Email for article apps,
        // Auto-Download for media apps), then the universal tail. Contacts is
        // email sharing's address book, so it appears only where email exists.
        KindWiring.settingsCategories()
        + (AppSurfaceConfig.current.sharesByEmail
            ? [SettingsCategory(title: "Contacts", symbol: "person.2") { FriendsViewController() }]
            : [])
        + [
            SettingsCategory(title: "Shortcut & Safari", symbol: "safari") { ShortcutSettingsScreen() },
            SettingsCategory(title: "Appearance", symbol: "circle.lefthalf.filled") { AppearanceSettingsScreen() },
            SettingsCategory(title: "Diagnostics", symbol: "ladybug") { DiagnosticsViewController() },
        ]

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = "Settings"
        super.viewDidLoad()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Detail values can change on pushed screens. Refresh rows when the
        // user comes back so they are immediately visible.
        tableView.reloadData()
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        categories.count
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        let category = categories[indexPath.row]
        content.text = category.title
        content.secondaryText = category.detail?()
        content.image = UIImage(systemName: category.symbol)
        cell.accessoryType = .disclosureIndicator
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard categories.indices.contains(indexPath.row) else { return }
        navigationController?.pushViewController(categories[indexPath.row].make(), animated: true)
    }
}

// (ReaderSettingsScreen + ReadingListSettingsScreen moved to
// `ReaderSettingsScreens.swift` — article-kind, per-target compiled.)
// MARK: - Shortcut & Safari

final class ShortcutSettingsScreen: NavHeaderTableController {
    /// Section 0: the Safari extension's surface-specific button visibility.
    /// Then the media apps' background-download preference, and the Action-Button
    /// shortcut's URL preference and actions.
    private enum Section: Int, CaseIterable {
        case suggestionButton, backgroundDownload, onScreenURLs, shortcut
    }
    private enum Row: Int, CaseIterable { case install, openShortcuts, refreshStatus }
    private var safariStatusText = ""
    private var safariButtonName: String {
        switch AppSurfaceConfig.current {
        case .all: return "Luna"
        case .reader: return "Read in Luna"
        case .downloader: return "Download"
        case .priceTracker: return "Track in Luna"
        }
    }
    /// Only the media-handling apps' intents download media, so only they show the
    /// background-download row (the pref itself lives in `AppIntentSettings`, which
    /// every app links — `LunaMediaDownload` is not universal).
    private var handlesMedia: Bool {
        switch AppSurfaceConfig.current {
        case .all, .downloader: return true
        case .reader, .priceTracker: return false
        }
    }
    private var visibleSections: [Section] {
        var sections: [Section] = [.suggestionButton]
        if handlesMedia { sections.append(.backgroundDownload) }
        if #available(iOS 27.0, *) { sections += [.onScreenURLs, .shortcut] }
        return sections
    }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = "Shortcut & Safari"
        super.viewDidLoad()
        refreshSafariStatus()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { visibleSections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch visibleSections[section] {
        case .suggestionButton: return 1
        case .backgroundDownload: return 1
        case .onScreenURLs: return 1
        case .shortcut: return Row.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch visibleSections[section] {
        case .suggestionButton: return "\(safariButtonName) Button"
        case .backgroundDownload: return "Media"
        case .onScreenURLs: return "On-Screen URLs"
        case .shortcut: return "Action Button Shortcut"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch visibleSections[section] {
        case .suggestionButton:
            return "When browsing in Safari (with the Luna extension enabled), show the "
                + "\"\(safariButtonName)\" button when it applies. Choose when it appears."
        case .backgroundDownload:
            return "When on, Save and Provide Context return right away and the media keeps downloading in the background with a Live Activity. When off, they wait for the download to finish and return the image or video to your shortcut."
        case .onScreenURLs:
            return "When enabled, Provide Context can save a complete URL detected on screen. Turn this off to ignore supplied on-screen URLs and use the normal app or screenshot handling."
        case .shortcut:
            let base = "Save the Safari webpage by pressing the Action Button: enable the Luna Safari extension (Settings → Apps → Safari → Extensions), install the shortcut, then pick \"\(BundledShortcut.displayName)\" in Settings → Action Button.\n\n\(safariStatusText)"
            return base
        }
    }

    override func tableView(
        _ tableView: UITableView, cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        if visibleSections[indexPath.section] == .suggestionButton {
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

        if visibleSections[indexPath.section] == .backgroundDownload {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            var content = cell.defaultContentConfiguration()
            content.text = "Download in Background"
            content.image = UIImage(systemName: "arrow.down.doc")
            cell.contentConfiguration = content
            cell.accessoryView = makeToggle(
                isOn: AppIntentSettings.downloadMediaInBackground,
                action: #selector(backgroundDownloadToggled(_:)))
            return cell
        }

        if visibleSections[indexPath.section] == .onScreenURLs {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            var content = cell.defaultContentConfiguration()
            content.text = "Handle On-Screen URLs"
            content.image = UIImage(systemName: "link")
            cell.contentConfiguration = content
            cell.accessoryView = makeToggle(
                isOn: AppIntentSettings.handleOnScreenURLs,
                action: #selector(handleOnScreenURLsToggled(_:)))
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

    @objc private func handleOnScreenURLsToggled(_ sender: UISwitch) {
        AppIntentSettings.handleOnScreenURLs = sender.isOn
    }

    @objc private func backgroundDownloadToggled(_ sender: UISwitch) {
        AppIntentSettings.downloadMediaInBackground = sender.isOn
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard visibleSections[indexPath.section] == .shortcut else { return }
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
