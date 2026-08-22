//
//  SettingsViewController.swift
//  Luna
//

import LunaSavesUI
import LunaSocialUI
import LunaSaves
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
        // UIKit drops a present() issued while another presentation is mid
        // dismissal — e.g. an alert action handler reporting its own outcome.
        // Wait for the presenter to become free while this screen is visible.
        guard presentedViewController == nil else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.viewIfLoaded?.window != nil else { return }
                self.presentInfoAlert(title: title, message: message)
            }
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_ok"), style: .default))
        present(alert, animated: true)
    }
}

/// A row of the top-level settings menu: a title, an SF Symbol, and the
/// subpage it pushes. The kind-specific leading rows come from each app's
/// `KindWiring` variant (`KindWiring.settingsCategories()`); the universal
/// tail is built here.
///
/// The three closures stay closures: this is a value describing one row,
/// written inline at its declaration site, and `detail`/`make`/
/// `makePrerequisite` are that row's own text and screen — not wiring
/// installed between components.
struct SettingsCategory {
    let title: String
    let symbol: String
    var detail: (() -> String?)? = nil
    var requiresEmail = false
    var makePrerequisite: (() -> UIViewController)? = nil
    let make: () -> UIViewController
}

/// Whether a sending account is connected. The rows that need one are dimmed and
/// redirect to the sign-in form until it is.
protocol EmailAccountStatusProviding {
    var isEmailAccountConnected: Bool { get }
}

/// The production answer: the shared account store.
struct ConnectedEmailAccountStatus: EmailAccountStatusProviding {
    var isEmailAccountConnected: Bool { EmailAccountStore.shared.isReady }
}

/// Top-level settings: a system-Settings-style menu that drills into a focused
/// subpage per category.
final class SettingsViewController: NavHeaderTableController, UIGestureRecognizerDelegate {
    /// Whether a sending account is connected — the gate on the rows that need
    /// one. Injected so a test can pin either answer without the App Group.
    private let emailStatus: any EmailAccountStatusProviding

    private let categories: [SettingsCategory] =
        // Kind rows first (Reader/Audio/Email/Kindle for article apps,
        // Auto-Download for media apps), then the universal tail. Contacts is
        // email sharing's address book, so it appears only where email exists.
        KindWiring.settingsCategories()
        + (LunaApp.current.sharesByEmail
            ? [SettingsCategory(title: L10n.string("Common_contacts"), symbol: "person.2") { FriendsViewController() }]
            : [])
        // Shortcut & Safari holds the suggestion-button toggle and the
        // cookie auto-decline switch (article apps only), the in-page video
        // player's off switch (media apps only), and the Action Button
        // shortcut sections (any device that can run one). Omit the whole
        // row rather than risk landing on a screen with nothing in it.
        + (LunaApp.current.handlesArticles || LunaApp.current.handlesMedia
            || ShortcutSettingsScreen.deviceHasShortcutSetup
            ? [SettingsCategory(title: ShortcutSettingsScreen.screenTitle(), symbol: "safari") { ShortcutSettingsScreen() }]
            : [])
        + [
            SettingsCategory(title: L10n.string("Settings_appearance_title"), symbol: "circle.lefthalf.filled") { AppearanceSettingsScreen() },
            // Universal: every app can hand its own links out and take a file
            // back, and each keeps only its own kinds either way.
            SettingsCategory(
                title: ImportExportSettingsScreen.screenTitle(),
                symbol: "arrow.up.arrow.down.square") { ImportExportSettingsScreen() },
        ]
        // The curator's proposal inbox. Settings is rebuilt on every visit, so
        // pasting the key in diagnostics and coming back is enough to reveal it.
        + (WeeklyPromotionKeyStore.isKeyHolder
            ? [SettingsCategory(title: L10n.string("Settings_weeklyProposals_title"), symbol: "crown") { WeeklyProposalsScreen() }]
            : [])

    init(emailStatus: any EmailAccountStatusProviding = ConnectedEmailAccountStatus()) {
        self.emailStatus = emailStatus
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        headerTitle = L10n.string("Common_settings")
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
        let enabled = !category.requiresEmail || emailStatus.isEmailAccountConnected
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
        guard !category.requiresEmail || emailStatus.isEmailAccountConnected else {
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
            title: L10n.string("Common_setUpEmailFirst"), message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_notNow"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("Common_ok"), style: .default) {
            [weak self] _ in
            guard let self, let prerequisite = category.makePrerequisite?() else { return }
            self.navigationController?.pushViewController(prerequisite, animated: true)
        })
        present(alert, animated: true)
    }
}

// (`ReaderSettingsScreen` lives in `ReaderSettingsScreens.swift` — article-kind,
// per-target compiled.)

/// Pushes the setup a repeat press still needs: the sign-in form when no email
/// account is connected, otherwise the Kindle address screen.
@MainActor
protocol KindleSetupPresenting {
    func presentKindleSetup(from presenter: UIViewController)
}

/// Article-kind seams the universal `ShortcutSettingsScreen` needs for its
/// double-save picker. Installed by the article shell of the two apps that link
/// LunaSend (Luna + Reader); left uninstalled in the other two apps, which don't
/// show the section at all.
enum DoubleSaveSettingsSupport {
    /// Pushes whichever setup the user is missing — the sign-in form when no
    /// email account is connected, otherwise the Kindle address screen.
    static var kindleSetupLauncher: (any KindleSetupPresenting)?

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
        case suggestionButton, cookiePopups, videoPlayer, onScreenURLs, doubleSave, shortcut
    }
    private enum Row: Int, CaseIterable { case install, openShortcuts, refreshStatus }
    private var safariStatusText = ""
    /// The double-save action is keyed per app (Luna and Reader each keep their
    /// own), and only those two arm it — see
    /// `ActionButtonIntentSupport.doubleSaveSurface`.
    private let doubleSaveSurface: DoubleSaveSurface? = LunaApp.current.doubleSaveSurface
    private var safariButtonName: String {
        L10n.string("Settings_shortcut_safariButtonName")
    }
    /// Whether this device has an Action Button shortcut to set up. It needs
    /// the OS that can run the bundled shortcut and hardware with an Action
    /// Button to assign it to. Asked of the same helper the onboarding save
    /// lesson asks (`OnboardingSaveSetupMode`), so Settings and the util card
    /// can never disagree about which save route this device is being taught.
    ///
    /// Nothing about the Safari extension is behind this: `nativeMessaging`
    /// — and so the extension's page buttons, its unlocking, and the
    /// recent-URL history the util card offers — runs on every OS Luna
    /// supports.
    static var deviceHasShortcutSetup: Bool {
        OnboardingSaveSetupMode.current == .actionButtonShortcut
    }

    /// Settings' row title, and this screen's own header: with no shortcut to set
    /// up, this screen IS the Safari extension's settings and says so.
    static func screenTitle(showsShortcutSetup: Bool = deviceHasShortcutSetup) -> String {
        showsShortcutSetup ? L10n.string("Settings_shortcut_titleWithSetup") : L10n.string("Settings_shortcut_titleSafariOnly")
    }

    private let showsShortcutSetup: Bool

    private var visibleSections: [Section] {
        // The suggestion pill only ever fires on article pages, so its toggle
        // is meaningless outside the two apps that handle articles.
        var sections: [Section] = LunaApp.current.handlesArticles ? [.suggestionButton] : []
        // Cookie auto-decline is a reading comfort. The two apps whose users
        // spend their Safari time on article pages own the choice, and the
        // Downloader and Price Tracker keep it always on with no control:
        // their extensions never read the key, so an "off" here cannot
        // reach them through the shared App Group suite.
        if LunaApp.current.handlesArticles { sections.append(.cookiePopups) }
        // The in-page video player is media handling, and only the two
        // media-handling apps' extensions ever open one
        // (`claudedocs/safari-extension.md`).
        if LunaApp.current.handlesMedia { sections.append(.videoPlayer) }
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
        case .cookiePopups: return 1
        case .videoPlayer: return 1
        case .onScreenURLs: return 1
        case .doubleSave: return 1
        case .shortcut: return Row.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch visibleSections[section] {
        case .suggestionButton: return L10n.string("Settings_shortcut_suggestionButtonSectionHeader", safariButtonName)
        case .cookiePopups: return L10n.string("Settings_shortcut_cookiePopupsSectionHeader")
        case .videoPlayer: return L10n.string("Settings_shortcut_videoPlayerSectionHeader")
        case .onScreenURLs: return L10n.string("Settings_shortcut_onScreenURLsSectionHeader")
        case .doubleSave: return L10n.string("Settings_shortcut_doubleSaveSectionHeader")
        case .shortcut: return L10n.string("Settings_shortcut_shortcutSectionHeader")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch visibleSections[section] {
        case .suggestionButton:
            return L10n.string("Settings_shortcut_suggestionButtonFooter", safariButtonName)
        case .cookiePopups:
            return L10n.string("Settings_shortcut_cookiePopupsFooter")
        case .videoPlayer:
            return L10n.string("Settings_shortcut_videoPlayerFooter", safariButtonName)
        case .onScreenURLs:
            return L10n.string("Settings_shortcut_onScreenURLsFooter")
        case .doubleSave:
            return L10n.string("Settings_shortcut_doubleSaveFooter")
        case .shortcut:
            return L10n.string("Settings_shortcut_installFooter", BundledShortcut.displayName, safariStatusText)
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
            // Centers at the control's natural height; pinning top and bottom
            // would stretch it taller than a normal segmented control and look off.
            NSLayoutConstraint.activate([
                control.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                control.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                control.centerYAnchor.constraint(equalTo: cell.contentView.centerYAnchor),
                control.topAnchor.constraint(greaterThanOrEqualTo: cell.contentView.topAnchor, constant: 8),
                control.bottomAnchor.constraint(lessThanOrEqualTo: cell.contentView.bottomAnchor, constant: -8),
            ])
            return cell
        }

        if visibleSections[indexPath.section] == .cookiePopups {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            var content = cell.defaultContentConfiguration()
            content.text = L10n.string("Settings_shortcut_cookiePopupsToggleLabel")
            content.image = UIImage(systemName: "hand.raised")
            cell.contentConfiguration = content
            cell.accessoryView = makeToggle(
                isOn: SafariSuggestionSettings.cookieAutoDeclineEnabled,
                action: #selector(cookieAutoDeclineToggled(_:)))
            return cell
        }

        if visibleSections[indexPath.section] == .videoPlayer {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            var content = cell.defaultContentConfiguration()
            content.text = L10n.string("Settings_shortcut_videoPlayerToggleLabel")
            content.image = UIImage(systemName: "play.rectangle")
            cell.contentConfiguration = content
            cell.accessoryView = makeToggle(
                isOn: SafariSuggestionSettings.videoPlayerEnabled,
                action: #selector(videoPlayerToggled(_:)))
            return cell
        }

        if visibleSections[indexPath.section] == .doubleSave {
            return doubleSaveActionCell()
        }

        if visibleSections[indexPath.section] == .onScreenURLs {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            cell.selectionStyle = .none
            var content = cell.defaultContentConfiguration()
            content.text = L10n.string("Settings_shortcut_onScreenURLsToggleLabel")
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
            content.text = L10n.string("Common_installShortcut")
            content.image = UIImage(systemName: "square.and.arrow.down")
        case .openShortcuts:
            content.text = L10n.string("Settings_shortcut_openShortcutsRow")
            content.image = UIImage(systemName: "arrow.up.forward.app")
        case .refreshStatus:
            content.text = L10n.string("Settings_shortcut_refreshStatusRow")
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
        content.text = L10n.string("Settings_shortcut_doubleSaveActionLabel")
        content.image = UIImage(systemName: "hand.tap")
        cell.contentConfiguration = content

        let button = UIButton(type: .system)
        button.setTitle(current.displayName, for: .normal)
        button.accessibilityIdentifier = "doubleSaveActionPicker"
        button.accessibilityLabel = L10n.string("Settings_shortcut_doubleSaveActionLabel")
        button.showsMenuAsPrimaryAction = true
        button.menu = menu
        button.sizeToFit()
        cell.accessoryView = button
        return cell
    }

    /// Stores the choice, then — for Kindle without a configured destination —
    /// offers the setup it needs. The choice is kept either way: it becomes
    /// live the moment Kindle is set up, and a repeat press does nothing until
    /// then (`SavesIngestor.resolvedIntentAction`).
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
            title: L10n.string("Settings_shortcut_kindleSetupPromptTitle"),
            message: L10n.string("Settings_shortcut_kindleSetupPromptMessage"),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_notNow"), style: .cancel))
        alert.addAction(UIAlertAction(title: L10n.string("Settings_shortcut_kindleSetupPromptButton"), style: .default) {
            [weak self] _ in
            guard let self else { return }
            DoubleSaveSettingsSupport.kindleSetupLauncher?.presentKindleSetup(from: self)
        })
        present(alert, animated: true)
    }

    @objc private func suggestionModeChanged(_ control: UISegmentedControl) {
        let modes = SafariSuggestionMode.allCases
        SafariSuggestionSettings.mode = modes[max(0, min(control.selectedSegmentIndex, modes.count - 1))]
    }

    @objc private func cookieAutoDeclineToggled(_ sender: UISwitch) {
        SafariSuggestionSettings.cookieAutoDeclineEnabled = sender.isOn
    }

    @objc private func videoPlayerToggled(_ sender: UISwitch) {
        SafariSuggestionSettings.videoPlayerEnabled = sender.isOn
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
            } ?? L10n.string("Settings_shortcut_unknownTimeFallback")
            safariStatusText = L10n.string("Settings_shortcut_lastVisitedStatus", when, url)
        } else {
            safariStatusText = L10n.string("Settings_shortcut_noSafariURLStatus")
        }
    }
}
