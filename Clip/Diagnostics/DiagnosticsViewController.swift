//
//  DiagnosticsViewController.swift
//  Clip
//

import UIKit

/// Shows the persistent diagnostic log and lets the user share it (as a `.txt`)
/// or clear it. Reached from Settings → Diagnostics. Used to debug push /
/// CloudKit delivery on devices where Console.app can't read the log archive.
final class DiagnosticsViewController: UIViewController {

    private let log: DiagnosticLogging
    private let textView = UITextView()

    init(log: DiagnosticLogging = DiagnosticLog.shared) {
        self.log = log
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Diagnostics"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemBackground

        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        textView.textColor = .label
        textView.alwaysBounceVertical = true
        textView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Keep both actions on the right so the navigation back button (the way
        // out of this screen) stays in place. When presented modally rather than
        // pushed, add an explicit Done button.
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(barButtonSystemItem: .action, target: self, action: #selector(share)),
            UIBarButtonItem(title: "Clear", style: .plain, target: self, action: #selector(clear)),
        ]
        if navigationController?.viewControllers.first === self || navigationController == nil {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .done, target: self, action: #selector(done))
        }
    }

    @objc private func done() {
        if let navigationController, navigationController.viewControllers.count > 1 {
            navigationController.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
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
        activity.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
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
