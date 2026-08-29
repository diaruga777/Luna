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
import UniformTypeIdentifiers

public enum LunaVaultUIModule {
    public static let identifier = "LunaVaultUI"
}

/// Search-first root owned by the Vault UI package. Storage and sync remain
/// injected through `VaultRuntimeServices`; this surface only reports whether
/// the selected backend is currently usable.
public final class VaultRootViewController: UIViewController {
    private let services: VaultRuntimeServices?
    private let importHandler: ((VaultImportSource) throws -> VaultImportResult)?
    private let searchField: UITextField
    private let statusLabel: UILabel

    /// `importHandler` is injected by the app composition root. Keeping the
    /// document-provider URL in this controller only for the duration of the
    /// picker callback means extensions never receive a source URL or an
    /// encryption capability.
    public init(services: VaultRuntimeServices? = nil,
                importHandler: ((VaultImportSource) throws -> VaultImportResult)? = nil) {
        self.services = services
        self.importHandler = importHandler
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
        updateStatus()
        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.textColor = .secondaryLabel

        view.addSubview(searchField)
        view.addSubview(statusLabel)
        if importHandler != nil {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Import", style: .plain, target: self,
                action: #selector(importDocuments))
            navigationItem.rightBarButtonItem?.accessibilityLabel = "Import files"
        }
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

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateStatus()
    }

    private func updateStatus() {
        guard let services else {
            statusLabel.text = "Luna Vault\nStorage setup needs attention."
            return
        }
        guard services.isReady else {
            if services.policy.location == .mac {
                statusLabel.text = "Luna Vault\nPair your Mac to sync encrypted files."
                return
            }
            switch services.availability {
            case .unavailable:
                statusLabel.text = "Luna Vault\niCloud is unavailable. Check your Apple ID and iCloud Drive."
            case .failed:
                statusLabel.text = "Luna Vault\niCloud reported a storage error. Try again later."
            case .needsDownload, .downloading, .evicting:
                statusLabel.text = "Luna Vault\niCloud is preparing your vault."
            case .available:
                statusLabel.text = "Luna Vault\nStorage setup needs attention."
            }
            return
        }
        let location = services.policy.location == .iCloud ? "iCloud" : "this device"
        statusLabel.text = "Luna Vault\nReady on \(location)."
    }

    @objc private func importDocuments() {
        guard importHandler != nil else { return }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item],
                                                     asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    private func reportImport(_ result: Result<VaultImportResult, Error>) {
        let message: String
        switch result {
        case .success(let imported):
            message = "Imported \(imported.fileName)"
        case .failure:
            message = "The file could not be imported. It remains outside your vault."
        }
        let alert = UIAlertController(title: "Luna Vault", message: message,
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension VaultRootViewController: UIDocumentPickerDelegate {
    public func documentPicker(_ controller: UIDocumentPickerViewController,
                               didPickDocumentsAt urls: [URL]) {
        guard let importHandler else { return }
        for url in urls {
            let source = VaultImportSource(
                fileURL: url,
                fileName: url.lastPathComponent,
                contentType: UTType(filenameExtension: url.pathExtension)?.identifier)
            // Import is synchronous by design at the setup boundary, but it
            // must never block UIKit's document-provider callback queue.
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let result = Result { try importHandler(source) }
                DispatchQueue.main.async { [weak self] in
                    self?.reportImport(result)
                }
            }
        }
    }
}
