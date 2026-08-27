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
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
