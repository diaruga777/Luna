//
//  DiagnosticsViewController.swift
//  Luna
//

import LunaStorage
import LunaDesignSystem
import UIKit

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

    init(log: DiagnosticLogging = DiagnosticLog.shared) {
        self.log = log
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .label
        textView.alwaysBounceVertical = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)

        header.title = "Diagnostics"
        // The way out: a back chevron when pushed; Done when the root (modal). Mirrors the
        // old conditional left bar button. The trailing actions (share / clear / replays)
        // sit on the right, as before.
        let isRoot = navigationController?.viewControllers.first === self || navigationController == nil
        if isRoot {
            header.setLeadingControls([NavHeaderBar.textButton(
                title: "Done", target: self, action: #selector(headerBack), bold: true)])
        } else {
            header.setLeadingControls([NavHeaderBar.backButton(target: self, action: #selector(headerBack))])
        }
        header.setTrailingControls([
            NavHeaderBar.imageButton(
                systemName: "square.and.arrow.up", target: self, action: #selector(share),
                accessibilityLabel: "Share"),
            NavHeaderBar.textButton(title: "Clear", target: self, action: #selector(clear)),
            NavHeaderBar.textButton(title: "Replays", target: self, action: #selector(openReplays)),
        ])
        let headerBottom = header.mount(in: self)

        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: headerBottom),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func headerBack() {
        if let navigationController, navigationController.viewControllers.count > 1 {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    @objc private func openReplays() {
        let replays = ReplaysViewController()
        if let navigationController {
            navigationController.pushViewController(replays, animated: true)
        } else {
            let nav = UINavigationController(rootViewController: replays)
            present(nav, animated: true)
        }
    }


    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: false)
        reload()
    }

    private func reload() {
        let text = log.contents()
        textView.text = text.isEmpty ? "No diagnostics recorded yet." : text
        // Show the most recent lines.
        textView.layoutIfNeeded()
        let end = NSRange(location: (textView.text as NSString).length, length: 0)
        textView.scrollRangeToVisible(end)
    }

    @objc private func share() {
        guard let url = try? log.exportFile() else {
            presentAlert(title: "Export Failed", message: "Couldn't write the log file.")
            return
        }
        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        activity.popoverPresentationController?.sourceView = header
        present(activity, animated: true)
    }

    @objc private func clear() {
        let confirm = UIAlertController(
            title: "Clear Diagnostics?",
            message: "This erases the saved log.", preferredStyle: .alert)
        confirm.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        confirm.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            self?.log.clear()
            self?.reload()
        })
        present(confirm, animated: true)
    }

    private func presentAlert(title: String, message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
