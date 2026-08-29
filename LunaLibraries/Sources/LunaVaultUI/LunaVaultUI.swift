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

public final class VaultRuntimeServices: @unchecked Sendable {
    public let repository: VaultRepository
    public let rootKeyManager: VaultRootKeyManager
    public let backend: (any VaultBackendTransport)?
    public let syncConfiguration: VaultSyncConfiguration
    public init(repository: VaultRepository, rootKeyManager: VaultRootKeyManager,
                backend: (any VaultBackendTransport)?,
                syncConfiguration: VaultSyncConfiguration) {
        self.repository = repository; self.rootKeyManager = rootKeyManager
        self.backend = backend; self.syncConfiguration = syncConfiguration
    }
}

/// Search-first surface owned by the Vault UI package. Repository and backend
/// work stays behind `VaultRuntimeServices`; this controller only composes the
/// user-facing surface and does not expose keys to extensions.
public final class VaultRootViewController: UIViewController {
    private let runtime: VaultRuntimeServices?
    private let searchField: UITextField
    private let statusLabel: UILabel

    public init(runtime: VaultRuntimeServices? = nil) {
        self.runtime = runtime
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
        statusLabel.text = runtime?.backend == nil
            ? "Luna Vault\nYour encrypted files will appear here."
            : "Luna Vault\nEncrypted Mac sync is configured."
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
