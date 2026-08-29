import LunaDesignSystem
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultEmbeddings
import LunaVaultIndexExtraction
import LunaVaultModels
import LunaVaultSearch
import LunaVaultSetup
import LunaVaultStorage
import LunaVaultSync
import UIKit

public enum LunaVaultUIModule {
    public static let identifier = "LunaVaultUI"
}

/// Search-first placeholder owned by the Vault UI package. It intentionally
/// performs no storage, provider, extraction or indexing work in Stage 1.
public final class VaultRootViewController: UIViewController {
    private let searchField: UITextField
    private let statusLabel: UILabel

    private let services: VaultRuntimeServices?

    public init(services: VaultRuntimeServices? = nil) {
        self.services = services
        searchField = UITextField()
        statusLabel = UILabel()
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Luna Vault"

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholder = "Search your vault"
        searchField.accessibilityLabel = "Vault search"
        searchField.borderStyle = .roundedRect
        searchField.returnKeyType = .search

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        if let services {
            let location = services.policy.location == .iCloud ? "iCloud" : "this device"
            statusLabel.text = "Luna Vault\nReady on \(location)."
        } else {
            statusLabel.text = "Luna Vault\nStorage setup needs attention."
        }
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.textColor = .secondaryLabel

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
