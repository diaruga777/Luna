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
import LunaMailAccount
import LunaWeekly
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
        alert.addAction(UIAlertAction(title: L10n.string("OK"), style: .default))
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
    var requiresEmail = false
    var makePrerequisite: (() -> UIViewController)? = nil
    let make: () -> UIViewController
}

/// Top-level settings: a system-Settings-style menu that drills into a focused
/// subpage per category.
final class SettingsViewController: NavHeaderTableController, UIGestureRecognizerDelegate {
    private let emailIsConfigured: () -> Bool

    private let categories: [SettingsCategory] =
        // Kind rows first (Reader/Audio/Reading List/Email for article apps,
        // Auto-Download for media apps), then the universal tail. Contacts is
        // email sharing's address book, so it appears only where email exists.
        KindWiring.settingsCategories()
        + (LunaApp.current.sharesByEmail
            ? [SettingsCategory(title: L10n.string("Contacts"), symbol: "person.2") { FriendsViewController() }]
            : [])
        + [
            SettingsCategory(title: ShortcutSettingsScreen.screenTitle(), symbol: "safari") { ShortcutSettingsScreen() },
            SettingsCategory(title: L10n.string("Appearance"), symbol: "circle.lefthalf.filled") { AppearanceSettingsScreen() },
        ]
        // The curator's proposal inbox. Settings is rebuilt on every visit, so
        // pasting the key in diagnostics and coming back is enough to reveal it.
        + (WeeklyPromotionKeyStore.isKeyHolder
            ? [SettingsCategory(title: L10n.string("Save of the Week"), symbol: "crown") { WeeklyProposalsScreen() }]
            : [])

    init(emailIsConfigured: @escaping () -> Bool = {
        EmailAccountStore.shared.isReady
    }) {
        self.emailIsConfigured = emailIsConfigured
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = L10n.string("Settings")
        super.viewDidLoad()
        let diagnosticsGesture = UITapGestureRecognizer(
            target: self, action: #selector(openDiagnostics))
        diagnosticsGesture.numberOfTapsRequired = 5
        diagnosticsGesture.cancelsTouchesInView = false
        diagnosticsGesture.delegate = self
        tableView.addGestureRecognizer(diagnosticsGesture)
        NotificationCenter.default.addObserver(
            self, selector: #selector(emailAccountStatusChanged),
            name: EmailAccountStore.accountChanged, object: nil)
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
        let enabled = !category.requiresEmail || emailIsConfigured()
        content.textProperties.color = enabled ? LunaColors.primaryText : LunaColors.tertiaryText
        content.imageProperties.tintColor = enabled ? view.tintColor : LunaColors.tertiaryText
        cell.accessoryType = .disclosureIndicator
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard categories.indices.contains(indexPath.row) else { return }
        let category = categories[indexPath.row]
        guard !category.requiresEmail || emailIsConfigured() else {
            presentEmailRequiredAlert(for: category)
            return
        }
        navigationController?.pushViewController(category.make(), animated: true)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch
    ) -> Bool {
        var touchedView: UIView? = touch.view
        while let view = touchedView {
            if view is UITableViewCell || view is UIControl { return false }
            if view === tableView { return true }
            touchedView = view.superview
        }
        return false
    }

    @objc private func openDiagnostics() {
        navigationController?.pushViewController(DiagnosticsViewController(), animated: true)
    }

    @objc private func emailAccountStatusChanged() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.emailAccountStatusChanged() }
            return
        }
        guard isViewLoaded else { return }
        tableView.reloadData()
    }

    private func presentEmailRequiredAlert(for category: SettingsCategory) {
        let alert = UIAlertController(
            title: L10n.string("Set up email first"), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Not Now"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("OK"), style: .default) {
            [weak self] _ in
            guard let self, let prerequisite = category.makePrerequisite?() else { return }
            self.navigationController?.pushViewController(prerequisite, animated: true)
        })
        present(alert, animated: true)
    }
}

// (`ReaderSettingsScreen` lives in `ReaderSettingsScreens.swift` — article-kind,
// per-target compiled.)

/// Article-kind seams the universal `ShortcutSettingsScreen` needs for its
/// double-save picker. Installed by the two `KindWiring` variants that link
/// LunaSend (Luna + Reader); nil in the other two apps, which don't show the
/// section at all.
enum DoubleSaveSettingsSupport {
    /// Pushes whichever setup the user is missing — the sign-in form when no
    /// email account is connected, otherwise the Kindle address screen.
    static var kindleSetupLauncher: ((UIViewController) -> Void)?

    /// Whether a repeat press could actually reach a Kindle right now.
    static var isKindleConfigured: Bool {
        IngestorKindHandlers.article?.isDestinationConfigured(
            ArticleDestinationID.kindle) ?? false
    }
}

// MARK: - Shortcut & Safari

final class ShortcutSettingsScreen: NavHeaderTableController {
    /// Section 0: the Safari extension's surface-specific button visibility —
    /// the extension needs no particular OS or hardware, so it is always here.
    /// Then the Action-Button shortcut's URL preference, double-save action,
    /// and actions, which are here only on a device that can run the shortcut.
    private enum Section: Int, CaseIterable {
        case suggestionButton, onScreenURLs, doubleSave, shortcut
    }
    private enum Row: Int, CaseIterable { case install, openShortcuts, refreshStatus }
    private var safariStatusText = ""
    /// The double-save action is keyed per app (Luna and Reader each keep their
    /// own), and only those two arm it — see
    /// `ActionButtonIntentSupport.doubleSaveSurface`.
    private let doubleSaveSurface: String? = {
        switch LunaApp.current {
        case .luna, .reader: return LunaApp.current.storageIdentifier
        case .downloader, .priceTracker: return nil
        }
    }()
    private var safariButtonName: String {
        switch LunaApp.current {
        case .luna: return L10n.string("Luna")
        case .reader: return L10n.string("Read in Luna")
        case .downloader: return L10n.string("Download")
        case .priceTracker: return L10n.string("Track in Luna")
        }
    }
    /// Whether THIS device has an Action Button shortcut to set up: it needs the
    /// OS that can run the bundled shortcut AND hardware with an Action Button to
    /// assign it to. Asked of the same helper the onboarding save lesson asks
    /// (`OnboardingSaveSetupMode`), so Settings and the util card can never
    /// disagree about which save route this device is being taught.
    ///
    /// Nothing about the Safari extension is behind this: `nativeMessaging` — and
    /// so the extension's page buttons, its unlocking, and the recent-URL history
    /// the util card offers — runs on every OS Luna supports.
    static var deviceHasShortcutSetup: Bool {
        OnboardingSaveSetupMode.current == .actionButtonShortcut
    }

    /// Settings' row title, and this screen's own header: with no shortcut to set
    /// up, this screen IS the Safari extension's settings and says so.
    static func screenTitle(showsShortcutSetup: Bool = deviceHasShortcutSetup) -> String {
        showsShortcutSetup ? L10n.string("Shortcut & Safari") : L10n.string("Safari")
    }

    private let showsShortcutSetup: Bool

    private var visibleSections: [Section] {
        var sections: [Section] = [.suggestionButton]
        guard showsShortcutSetup else { return sections }
        sections.append(.onScreenURLs)
        // Double save is a behavior of the Action Button shortcut, so it
        // only shows where that shortcut does — and only in the apps that
        // can act on it.
        if doubleSaveSurface != nil { sections.append(.doubleSave) }
        sections.append(.shortcut)
        return sections
    }

    init(showsShortcutSetup: Bool = ShortcutSettingsScreen.deviceHasShortcutSetup) {
        self.showsShortcutSetup = showsShortcutSetup
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = Self.screenTitle(showsShortcutSetup: showsShortcutSetup)
        super.viewDidLoad()
        refreshSafariStatus()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { visibleSections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch visibleSections[section] {
        case .suggestionButton: return 1
        case .onScreenURLs: return 1
        case .doubleSave: return 1
        case .shortcut: return Row.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch visibleSections[section] {
        case .suggestionButton: return L10n.string("\(safariButtonName) Button")
        case .onScreenURLs: return L10n.string("On-Screen URLs")
        case .doubleSave: return L10n.string("Double Save Articles")
        case .shortcut: return L10n.string("Action Button Shortcut")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch visibleSections[section] {
        case .suggestionButton:
            return L10n.string("When browsing in Safari (with the Luna extension enabled), show the \"\(safariButtonName)\" button when it applies. Choose when it appears.")
        case .onScreenURLs:
            return L10n.string("When enabled, Provide Context can save a complete URL detected on screen. Turn this off to ignore supplied on-screen URLs and use the normal app or screenshot handling.")
        case .doubleSave:
            return L10n.string("For saved articles only: press the Action Button twice on the same article within 7 seconds. Send to Kindle emails the article; View immediately returns a self-contained Word document to the shortcut. Videos, posts, products, and imported documents ignore the second press.")
        case .shortcut:
            let base = L10n.string("Save the Safari webpage by pressing the Action Button: enable the Luna Safari extension (Settings → Apps → Safari → Extensions), install the shortcut, then pick \"\(BundledShortcut.displayName)\" in Settings → Action Button.\n\n\(safariStatusText)")
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

        if visibleSections[indexPath.section] == .doubleSave {
            return doubleSaveActionCell()
        }

        if visibleSections[indexPath.section] == .onScreenURLs {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            var content = cell.defaultContentConfiguration()
            content.text = L10n.string("Handle On-Screen URLs")
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
            content.text = L10n.string("Install Shortcut")
            content.image = UIImage(systemName: "square.and.arrow.down")
        case .openShortcuts:
            content.text = L10n.string("Open Shortcuts")
            content.image = UIImage(systemName: "arrow.up.forward.app")
        case .refreshStatus:
            content.text = L10n.string("Refresh Last Visited Website")
            content.image = UIImage(systemName: "arrow.clockwise")
        }
        cell.contentConfiguration = content
        return cell
    }

    // MARK: - Double save

    /// A pull-down picker showing what a second Action Button press on the same
    /// saved article does.
    private func doubleSaveActionCell() -> UITableViewCell {
        let current = doubleSaveSurface.map {
            DoubleSaveActionStore.shared.action(forSurface: $0)
        } ?? DoubleSaveAction.nothing
        let menu = UIMenu(children: DoubleSaveAction.allCases.map { action in
            UIAction(
                title: action.displayName, state: action == current ? .on : .off
            ) { [weak self] _ in
                self?.apply(action)
            }
        })

        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.text = L10n.string("Second article save")
        content.image = UIImage(systemName: "hand.tap")
        cell.contentConfiguration = content

        let button = UIButton(type: .system)
        button.setTitle(current.displayName, for: .normal)
        button.accessibilityIdentifier = "doubleSaveActionPicker"
        button.accessibilityLabel = L10n.string("Second article save")
        button.showsMenuAsPrimaryAction = true
        button.menu = menu
        button.sizeToFit()
        cell.accessoryView = button
        return cell
    }

    /// Stores the choice, then — for Kindle without a configured destination —
    /// offers the setup it needs. The choice is kept either way: it becomes
    /// live the moment Kindle is set up, and a repeat press does nothing until
    /// then (`ReadingListIngestor.resolvedIntentAction`).
    private func apply(_ action: DoubleSaveAction) {
        guard let surface = doubleSaveSurface else { return }
        DoubleSaveActionStore.shared.setAction(action, forSurface: surface)
        if let section = visibleSections.firstIndex(of: .doubleSave) {
            tableView.reloadSections(IndexSet(integer: section), with: .none)
        }
        guard action == .sendToKindle, !DoubleSaveSettingsSupport.isKindleConfigured else {
            return
        }
        presentKindleSetupPrompt()
    }

    private func presentKindleSetupPrompt() {
        let alert = UIAlertController(
            title: L10n.string("Set up Kindle first"),
            message: L10n.string("Double Save Articles can't email an article until your Luna email account and Kindle address are set up."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Not Now"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("Set Up"), style: .default) {
            [weak self] _ in
            guard let self else { return }
            DoubleSaveSettingsSupport.kindleSetupLauncher?(self)
        })
        present(alert, animated: true)
    }

    @objc private func suggestionModeChanged(_ control: UISegmentedControl) {
        let modes = SafariSuggestionMode.allCases
        SafariSuggestionSettings.mode = modes[max(0, min(control.selectedSegmentIndex, modes.count - 1))]
    }

    @objc private func handleOnScreenURLsToggled(_ sender: UISwitch) {
        AppIntentSettings.handleOnScreenURLs = sender.isOn
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
            } ?? L10n.string("unknown time")
            safariStatusText = L10n.string("Last visited Safari URL (\(when)): \(url)")
        } else {
            safariStatusText = L10n.string(
                "No Safari URL tracked yet. Enable the Luna extension in Safari (Settings → Apps → Safari → Extensions) and browse to a page.")
        }
    }
}
