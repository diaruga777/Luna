import UIKit

/// The composition seam for Luna Vault. Provider, crypto, indexing and sync
/// services are intentionally absent in Stage 1; later stages install them
/// behind this boundary without making SceneDelegate a service locator.
enum VaultWiring {
    static func makeRootViewController() -> UIViewController {
        VaultRootViewController()
    }
}

/// Search-first placeholder root. It gives the standalone target a stable
/// launch surface while the real Vault library and indexing UI land later.
final class VaultRootViewController: UIViewController {
    private let searchField: UITextField = {
        let field = UITextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholder = "Search your vault"
        field.accessibilityLabel = "Vault search"
        field.borderStyle = .roundedRect
        field.returnKeyType = .search
        return field
    }()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = "Luna Vault\nYour encrypted files will appear here."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        return label
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Luna Vault"
        view.addSubview(searchField)
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            searchField.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            searchField.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            searchField.heightAnchor.constraint(equalToConstant: 48),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -24),
        ])
        searchField.becomeFirstResponder()
    }
}
