//
//  DiagnosticsViewController.swift
//  Luna
//

import LunaStorage
import LunaDesignSystem
import LunaSocial
import LunaWeekly
import UIKit
import LunaModels

/// Shows the persistent diagnostic log and lets the user share it (as a `.txt`)
/// or clear it. Reached from Settings → Diagnostics. Used to debug push /
/// CloudKit delivery on devices where Console.app can't read the log archive.
final class DiagnosticsViewController: UIViewController {

    private let log: DiagnosticLog
    /// Internal (not private) so the layout-sanity test can assert it's on-screen —
    /// the log content itself (live timestamps) isn't pixel-stable, so this screen is
    /// covered by a layout assertion rather than a snapshot.
    let textView = UITextView()
    /// In-content header in place of the nav bar.
    private let header = NavHeaderBar()
    private let eraseButton = UIButton(type: .system)
    /// The one place URL rescue is measurable. Internal so a test can read the
    /// rendered line without screenshotting a live log.
    let rescueStatsLabel = UILabel()
    private let rescueStats: RescueStatsStore
    /// Where the curator pastes the Save of the Week signing key. Hidden behind
    /// the same five taps as the log itself: it is not a user-facing feature.
    private let weeklyKeyButton = UIButton(type: .system)
    private let bottomButtons = UIStackView()
    /// Keeps left-edge swipe-back alive while the real nav bar is hidden.
    private let popGestureClaim = InteractivePopGestureClaim()

    init(log: DiagnosticLog = DiagnosticLog.shared,
         rescueStats: RescueStatsStore = .shared) {
        self.log = log
        self.rescueStats = rescueStats
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = LunaColors.background

        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = LunaColors.primaryText
        textView.alwaysBounceVertical = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        header.title = L10n.string("Settings_diagnostics_title")
        // The way out: a back chevron when pushed; Done when the root (modal). Mirrors the
        // old conditional left bar button. The trailing actions (share / clear)
        // sit on the right, as before.
        let isRoot = navigationController?.viewControllers.first === self || navigationController == nil
        if isRoot {
            header.setLeadingControls([NavHeaderBar.textButton(
                title: L10n.string("Common_done"), target: self, action: #selector(headerBack), bold: true)])
        } else {
            header.setLeadingControls([NavHeaderBar.backButton(target: self, action: #selector(headerBack))])
        }
        header.setTrailingControls([
            NavHeaderBar.imageButton(
                systemName: "square.and.arrow.up", target: self, action: #selector(share),
                accessibilityLabel: L10n.string("Common_share")),
            NavHeaderBar.textButton(title: L10n.string("Settings_diagnostics_clearButton"), target: self, action: #selector(clear)),
        ])
        let headerBottom = header.mount(in: self)

        rescueStatsLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        rescueStatsLabel.textColor = LunaColors.secondaryText
        rescueStatsLabel.numberOfLines = 0
        rescueStatsLabel.accessibilityIdentifier = "diagnostics.rescueStats"
        rescueStatsLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rescueStatsLabel)

        var eraseConfiguration = UIButton.Configuration.plain()
        eraseConfiguration.title = L10n.string("Settings_diagnostics_eraseAllDataButton")
        eraseConfiguration.baseForegroundColor = .systemRed
        eraseButton.configuration = eraseConfiguration
        eraseButton.accessibilityIdentifier = "diagnostics.eraseAllData"
        eraseButton.addTarget(self, action: #selector(confirmEraseEverything), for: .touchUpInside)
        weeklyKeyButton.accessibilityIdentifier = "diagnostics.weeklyKey"
        weeklyKeyButton.addTarget(
            self, action: #selector(weeklyKeyTapped), for: .touchUpInside)
        updateWeeklyKeyButton()

        bottomButtons.axis = .horizontal
        bottomButtons.alignment = .center
        bottomButtons.distribution = .equalCentering
        bottomButtons.spacing = 16
        bottomButtons.translatesAutoresizingMaskIntoConstraints = false
        bottomButtons.addArrangedSubview(weeklyKeyButton)
        bottomButtons.addArrangedSubview(eraseButton)
        view.addSubview(bottomButtons)

        NSLayoutConstraint.activate([
            rescueStatsLabel.topAnchor.constraint(equalTo: headerBottom, constant: 4),
            rescueStatsLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            rescueStatsLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            textView.topAnchor.constraint(equalTo: rescueStatsLabel.bottomAnchor, constant: 4),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(
                equalTo: bottomButtons.topAnchor, constant: -4),
            bottomButtons.leadingAnchor.constraint(
                greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            bottomButtons.trailingAnchor.constraint(
                lessThanOrEqualTo: view.trailingAnchor, constant: -16),
            bottomButtons.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            bottomButtons.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
        ])
    }

    // MARK: - Save of the Week key

    private func updateWeeklyKeyButton() {
        var configuration = UIButton.Configuration.plain()
        let hasKey = WeeklyPromotionKeyStore.isKeyHolder
        configuration.title = hasKey
            ? L10n.string("Settings_diagnostics_weeklyKeyActiveButton")
            : L10n.string("Settings_diagnostics_weeklyKeyEnterLabel")
        configuration.baseForegroundColor = hasKey
            ? .systemGreen : LunaColors.secondaryText
        weeklyKeyButton.configuration = configuration
        weeklyKeyButton.accessibilityLabel = configuration.title
    }

    @objc private func weeklyKeyTapped() {
        guard WeeklyPromotionKeyStore.isKeyHolder else {
            presentKeyEntry()
            return
        }
        let sheet = UIAlertController(
            title: L10n.string("Settings_diagnostics_weeklyKeySheetTitle"),
            message: L10n.string("Settings_diagnostics_weeklyKeyCanPromote"),
            preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(
            title: L10n.string("Settings_diagnostics_weeklyKeyReplaceButton"), style: .default
        ) { [weak self] _ in self?.presentKeyEntry() })
        sheet.addAction(UIAlertAction(
            title: L10n.string("Common_remove"), style: .destructive
        ) { [weak self] _ in
            WeeklyPromotionKeyStore.removeKey()
            DiagnosticLog.shared.record("weekly key removed", category: "weekly")
            self?.updateWeeklyKeyButton()
        })
        sheet.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = weeklyKeyButton
        present(sheet, animated: true)
    }

    private func presentKeyEntry() {
        let prompt = UIAlertController(
            title: L10n.string("Settings_diagnostics_weeklyKeyEnterLabel"),
            message: L10n.string("Settings_diagnostics_weeklyKeyPasteInstructions"),
            preferredStyle: .alert)
        prompt.addTextField { field in
            field.isSecureTextEntry = true
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.accessibilityIdentifier = "diagnostics.weeklyKeyField"
        }
        prompt.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        prompt.addAction(UIAlertAction(
            title: L10n.string("Common_save"), style: .default
        ) { [weak self, weak prompt] _ in
            self?.storeWeeklyKey(prompt?.textFields?.first?.text ?? "")
        })
        present(prompt, animated: true)
    }

    /// Internal so a test can drive the paste without a live alert.
    @discardableResult
    func storeWeeklyKey(_ pasted: String) -> Bool {
        guard WeeklyPromotionKeyStore.store(base64: pasted) else {
            DiagnosticLog.shared.record("weekly key rejected", category: "weekly")
            presentAlert(
                title: L10n.string("Settings_diagnostics_weeklyKeyWrongTitle"),
                message: L10n.string("Settings_diagnostics_weeklyKeyWrongMessage"))
            return false
        }
        DiagnosticLog.shared.record("weekly key accepted", category: "weekly")
        updateWeeklyKeyButton()
        // The curator now receives proposal notifications, so this is the
        // honest moment to ask.
        NotificationManager.requestAuthorization()
        WeeklyProposalBackgroundCheck.schedule(reason: "key pasted")
        presentAlert(
            title: L10n.string("Settings_diagnostics_weeklyKeyAcceptedTitle"),
            message: L10n.string("Settings_diagnostics_weeklyKeyAcceptedMessage"))
        return true
    }

    @objc private func headerBack() {
        if let navigationController, navigationController.viewControllers.count > 1 {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        reload()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        popGestureClaim.claim(in: navigationController)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        popGestureClaim.release()
    }

    /// "Rescue: 12 tried · 3 recovered (reroute 2, search 1) · 1 blocked".
    /// Rendered from the aggregate counters sidecar — the only measurement URL
    /// rescue has, and the answer to "has this ever accomplished anything".
    /// Internal so a test can assert the numbers reach the screen.
    func rescueStatsText() -> String {
        let stats = rescueStats.snapshot()
        guard stats.attempts > 0 else {
            return L10n.string("Settings_diagnostics_rescueStatsNone")
        }
        let recovered = stats.outcome(.rescued)
        let methods = stats.methodSummary
        let detail = methods.isEmpty
            ? L10n.string("Settings_diagnostics_rescueStatsRecovered", recovered)
            : L10n.string("Settings_diagnostics_rescueStatsRecoveredBy", recovered, methods)
        return L10n.string(
            "Settings_diagnostics_rescueStatsLine",
            stats.attempts, detail,
            stats.outcome(.browserHandoff), stats.outcome(.guardrailed))
    }

    private func reload() {
        rescueStatsLabel.text = rescueStatsText()
        let text = log.contents()
        textView.text = text.isEmpty ? L10n.string("Settings_diagnostics_emptyLogPlaceholder") : text
        // Show the most recent lines.
        textView.layoutIfNeeded()
        let end = NSRange(location: (textView.text as NSString).length, length: 0)
        textView.scrollRangeToVisible(end)
    }

    @objc private func share() {
        guard let url = try? log.exportFile() else {
            presentAlert(title: L10n.string("Settings_diagnostics_exportFailedTitle"), message: L10n.string("Settings_diagnostics_exportFailedMessage"))
            return
        }
        LunaShareSheet.present(items: [url], from: self, anchor: .view(header))
    }

    @objc private func clear() {
        let confirm = UIAlertController(
            title: L10n.string("Settings_diagnostics_clearConfirmTitle"),
            message: L10n.string("Settings_diagnostics_clearConfirmMessage"), preferredStyle: .alert)
        confirm.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        confirm.addAction(UIAlertAction(title: L10n.string("Settings_diagnostics_clearButton"), style: .destructive) { [weak self] _ in
            self?.log.clear()
            self?.reload()
        })
        present(confirm, animated: true)
    }

    /// The factory reset erases the whole install — both containers, both
    /// defaults domains, the shared keychain, notifications and the Spotlight
    /// index (`FactoryReset`) — so onboarding comes back as a consequence of
    /// there being nothing left rather than as a special case.
    ///
    /// It ends by QUITTING. Every store in the app is a singleton holding a
    /// decoded cache of a file that no longer exists, and the first one to write
    /// itself back would undo part of the wipe.
    @objc private func confirmEraseEverything() {
        let confirm = UIAlertController(
            title: L10n.string("Settings_diagnostics_eraseConfirmTitle"),
            message: L10n.string("Settings_diagnostics_eraseConfirmMessage"),
            preferredStyle: .alert)
        confirm.addAction(UIAlertAction(title: L10n.string("Common_cancel"), style: .cancel))
        confirm.addAction(UIAlertAction(
            title: L10n.string("Settings_diagnostics_eraseEverythingButton"), style: .destructive
        ) { [weak self] _ in self?.eraseEverything() })
        present(confirm, animated: true)
    }

    private func eraseEverything() {
        eraseButton.isEnabled = false
        Task { @MainActor in
            _ = await Task.detached(priority: .userInitiated) {
                await FactoryReset.eraseEverything()
            }.value
            let done = UIAlertController(
                title: L10n.string("Settings_diagnostics_erasedTitle"),
                message: L10n.string("Settings_diagnostics_erasedMessage"),
                preferredStyle: .alert)
            done.addAction(UIAlertAction(
                title: L10n.string("Settings_diagnostics_quitLunaButton"), style: .default
            ) { _ in exit(0) })
            self.present(done, animated: true)
        }
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("Common_ok"), style: .default))
        present(alert, animated: true)
    }
}
