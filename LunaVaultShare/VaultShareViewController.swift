import UIKit

/// Bounded Share extension handoff for Vault. The extension owns no provider,
/// crypto, or indexing lifecycle; it only confirms that the main app will
/// consume a future App Group inbox record.
final class VaultShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Save to Luna Vault"
        label.textAlignment = .center
        label.numberOfLines = 0

        let doneButton = UIButton(type: .system)
        doneButton.translatesAutoresizingMaskIntoConstraints = false
        doneButton.setTitle("Done", for: .normal)
        doneButton.addTarget(self, action: #selector(complete), for: .touchUpInside)

        let cancelButton = UIButton(type: .system)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.addTarget(self, action: #selector(cancel), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [cancelButton, doneButton])
        buttons.translatesAutoresizingMaskIntoConstraints = false
        buttons.axis = .horizontal
        buttons.spacing = 24
        buttons.distribution = .fillEqually

        view.addSubview(label)
        view.addSubview(buttons)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
            buttons.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            buttons.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),
            buttons.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 24),
        ])
    }

    /// Every path through this extension must end the request, or the host
    /// app's share sheet hangs indefinitely. Neither action here reads or
    /// stores the incoming item yet; both close the sheet the same way a
    /// future save would once the App Group inbox record exists.
    @objc private func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    @objc private func cancel() {
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}
