import UIKit
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultStorage
import LunaVaultSync
import LunaVaultUI

/// The composition seam for Luna Vault. The app owns construction of the
/// repository, root-key manager, and optional paired-Mac backend here; the
/// scene receives only the resulting runtime instead of locating services.
@MainActor enum VaultWiring {
    static func makeRootViewController() -> UIViewController {
        let identityConfirmer = VaultMacIdentityConfirmationPresenter()
        do {
            let accessGroup = Bundle.main.object(forInfoDictionaryKey: "LunaVaultKeychainAccessGroup") as? String
            guard let accessGroup, !accessGroup.isEmpty else { throw VaultMacProtocolError.unavailable }
            let rootKeys = VaultRootKeyManager(configuration:
                VaultCryptoConfiguration(keychainAccessGroup: accessGroup))
            let repository = try VaultRepository()
            let credentialStore = VaultMacKeychainCredentialStore(accessGroup: accessGroup,
                service: "\(Bundle.main.bundleIdentifier ?? "com.hsanabria.luna.vault").mac-pairing")
            let credential = try credentialStore.load()
            let backend: (any VaultBackendTransport)?
            if let credential, credential.revokedAt == nil {
                backend = try VaultMacRemoteBackend(
                    endpoint: VaultMacEndpoint(binding: credential.endpointBinding),
                    credential: credential, connector: VaultMacNWConnector(),
                    identityConfirmer: identityConfirmer)
            } else {
                backend = nil
            }
            let runtime = VaultRuntimeServices(repository: repository,
                rootKeyManager: rootKeys, backend: backend,
                syncConfiguration: VaultSyncConfiguration(location: backend == nil ? .device : .mac))
            let root = VaultRootViewController(runtime: runtime)
            identityConfirmer.attach(to: root)
            return root
        } catch {
            let root = VaultRootViewController()
            identityConfirmer.attach(to: root)
            return root
        }
    }
}

private final class VaultMacIdentityConfirmationPresenter:
    VaultMacServerIdentityConfirming, @unchecked Sendable {
    private weak var presenter: UIViewController?
    private let lock = NSLock()
    private var confirmedBindings: Set<String> = []

    @MainActor func attach(to presenter: UIViewController) { self.presenter = presenter }

    func confirm(fingerprint: String, endpointBinding: String) async throws
        -> VaultMacServerIdentityConfirmation? {
        if lock.withLock({ confirmedBindings.contains("\(fingerprint)|\(endpointBinding)") }) {
            return VaultMacServerIdentityConfirmation(fingerprint: fingerprint,
                endpointBinding: endpointBinding)
        }
        return await withCheckedContinuation { continuation in
            Task { @MainActor [weak self] in
                guard let self, let presenter = self.presenter else {
                    continuation.resume(returning: nil); return
                }
                let alert = UIAlertController(title: "Confirm your Mac",
                    message: "Compare this fingerprint on both devices:\n\n\(fingerprint)\n\nEndpoint: \(endpointBinding)",
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                    continuation.resume(returning: nil)
                })
                alert.addAction(UIAlertAction(title: "Fingerprints Match", style: .default) { [weak self] _ in
                    if let self {
                        self.lock.withLock {
                            self.confirmedBindings.insert("\(fingerprint)|\(endpointBinding)")
                        }
                    }
                    continuation.resume(returning: VaultMacServerIdentityConfirmation(
                        fingerprint: fingerprint, endpointBinding: endpointBinding))
                })
                presenter.present(alert, animated: true)
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T { lock(); defer { unlock() }; return body() }
}
