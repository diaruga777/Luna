//
//  DiagnosticsViewController.swift
//  Luna
//

import LunaStorage
import LunaDesignSystem
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
        resetOnboardingButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(resetOnboardingButton)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: headerBottom),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(
                equalTo: resetOnboardingButton.topAnchor, constant: -4),
            resetOnboardingButton.centerXAnchor.constraint(
                equalTo: view.centerXAnchor),
            resetOnboardingButton.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
        ])
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
