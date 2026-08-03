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

    private let log: DiagnosticLogging
    /// Internal (not private) so the layout-sanity test can assert it's on-screen —
    /// the log content itself (live timestamps) isn't pixel-stable, so this screen is
    /// covered by a layout assertion rather than a snapshot.
    let textView = UITextView()
    /// In-content header in place of the nav bar.
    private let header = NavHeaderBar()
    private let resetOnboardingButton = UIButton(type: .system)
    /// Where the curator pastes the Save of the Week signing key. Hidden behind
    /// the same five taps as the log itself: it is not a user-facing feature.
    private let weeklyKeyButton = UIButton(type: .system)
    private let bottomButtons = UIStackView()
    /// Keeps left-edge swipe-back alive while the real nav bar is hidden.
    private let popGestureClaim = InteractivePopGestureClaim()

    init(log: DiagnosticLogging = DiagnosticLog.shared) {
        self.log = log
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

        header.title = L10n.string("Diagnostics")
        // The way out: a back chevron when pushed; Done when the root (modal). Mirrors the
        // old conditional left bar button. The trailing actions (share / clear)
        // sit on the right, as before.
        let isRoot = navigationController?.viewControllers.first === self || navigationController == nil
        if isRoot {
            header.setLeadingControls([NavHeaderBar.textButton(
                title: L10n.string("Done"), target: self, action: #selector(headerBack), bold: true)])
        } else {
            header.setLeadingControls([NavHeaderBar.backButton(target: self, action: #selector(headerBack))])
        }
        header.setTrailingControls([
            NavHeaderBar.imageButton(
                systemName: "square.and.arrow.up", target: self, action: #selector(share),
                accessibilityLabel: L10n.string("Share")),
            NavHeaderBar.textButton(title: L10n.string("Clear"), target: self, action: #selector(clear)),
        ])
        let headerBottom = header.mount(in: self)

        var resetConfiguration = UIButton.Configuration.plain()
        resetConfiguration.title = L10n.string("Reset Onboarding")
        resetConfiguration.baseForegroundColor = .systemRed
        resetOnboardingButton.configuration = resetConfiguration
        resetOnboardingButton.accessibilityIdentifier = "diagnostics.resetOnboarding"
        resetOnboardingButton.addTarget(
            self, action: #selector(confirmResetOnboarding), for: .touchUpInside)
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
        bottomButtons.addArrangedSubview(resetOnboardingButton)
        view.addSubview(bottomButtons)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: headerBottom),
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
            ? L10n.string("Weekly Key ✓")
            : L10n.string("Enter Weekly Key")
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
            title: L10n.string("Save of the Week Key"),
            message: L10n.string("This device can promote Saves of the Week."),
            preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(
            title: L10n.string("Replace"), style: .default
        ) { [weak self] _ in self?.presentKeyEntry() })
        sheet.addAction(UIAlertAction(
            title: L10n.string("Remove"), style: .destructive
        ) { [weak self] _ in
            WeeklyPromotionKeyStore.removeKey()
            DiagnosticLog.shared.record("weekly key removed", category: "weekly")
            self?.updateWeeklyKeyButton()
        })
        sheet.addAction(UIAlertAction(title: L10n.string("Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = weeklyKeyButton
        present(sheet, animated: true)
    }

    private func presentKeyEntry() {
        let prompt = UIAlertController(
            title: L10n.string("Enter Weekly Key"),
            message: L10n.string(
                "Paste the Ed25519 private key. It is checked against the key built into this app; a wrong key is not stored."),
            preferredStyle: .alert)
        prompt.addTextField { field in
            field.isSecureTextEntry = true
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.accessibilityIdentifier = "diagnostics.weeklyKeyField"
        }
        prompt.addAction(UIAlertAction(title: L10n.string("Cancel"), style: .cancel))
        prompt.addAction(UIAlertAction(
            title: L10n.string("Save"), style: .default
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
                title: L10n.string("Wrong Key"),
                message: L10n.string(
                    "That key doesn't match this build. Nothing was stored."))
            return false
        }
        DiagnosticLog.shared.record("weekly key accepted", category: "weekly")
        updateWeeklyKeyButton()
        // The curator now receives proposal notifications, so this is the
        // honest moment to ask.
        NotificationManager.requestAuthorization()
        WeeklyProposalBackgroundCheck.schedule(reason: "key pasted")
        presentAlert(
            title: L10n.string("Key Accepted"),
            message: L10n.string("This device can now promote Saves of the Week."))
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

    private func reload() {
        let text = log.contents()
        textView.text = text.isEmpty ? L10n.string("No diagnostics recorded yet.") : text
        // Show the most recent lines.
        textView.layoutIfNeeded()
        let end = NSRange(location: (textView.text as NSString).length, length: 0)
        textView.scrollRangeToVisible(end)
    }

    @objc private func share() {
        guard let url = try? log.exportFile() else {
            presentAlert(title: L10n.string("Export Failed"), message: L10n.string("Couldn't write the log file."))
            return
        }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = header
        present(activity, animated: true)
    }

    @objc private func clear() {
        let confirm = UIAlertController(
            title: L10n.string("Clear Diagnostics?"),
            message: L10n.string("This erases the saved log."), preferredStyle: .alert)
        confirm.addAction(UIAlertAction(title: L10n.string("Cancel"), style: .cancel))
        confirm.addAction(UIAlertAction(title: L10n.string("Clear"), style: .destructive) { [weak self] _ in
            self?.log.clear()
            self?.reload()
        })
        present(confirm, animated: true)
    }

    /// Clears this app's onboarding completion plus every shared "has run"
    /// marker (Safari extension, App Intents shortcut), so the full first-run
    /// journey — including its setup steps — plays again on next launch.
    @objc private func confirmResetOnboarding() {
        let confirm = UIAlertController(
            title: L10n.string("Reset Onboarding?"),
            message: L10n.string(
                "Clears onboarding completion and the Safari extension and Shortcut run evidence. Full onboarding will show again on the next launch."),
            preferredStyle: .alert)
        confirm.addAction(UIAlertAction(title: L10n.string("Cancel"), style: .cancel))
        confirm.addAction(UIAlertAction(
            title: L10n.string("Reset"), style: .destructive
        ) { [weak self] _ in
            AppOnboardingStore.shared.resetCompletion()
            LunaSetupStatusStore.shared.resetAllRunEvidence()
            self?.presentAlert(
                title: L10n.string("Onboarding Reset"),
                message: L10n.string(
                    "Quit and relaunch the app to see the full onboarding."))
        })
        present(confirm, animated: true)
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L10n.string("OK"), style: .default))
        present(alert, animated: true)
    }
}
