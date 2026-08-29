import Foundation
import UIKit
import LunaAppConfig
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultSearch
import LunaVaultSetup
import LunaVaultStorage
import LunaVaultSync
import LunaVaultUI

/// The composition seam for Luna Vault. The app owns construction of the
/// repository, root-key manager, and optional paired-Mac backend here. The
/// scene receives only the resulting runtime instead of locating services.
@MainActor enum VaultWiring {
    private static var services: VaultRuntimeServices?
    private static var syncRuntime: VaultSyncRuntimeController?
    private static let setupCoordinator = VaultSetupCoordinator(
        configuration: VaultSetupConfiguration(
            keychainAccessGroup: Bundle.main.object(forInfoDictionaryKey: "LunaVaultKeychainAccessGroup") as? String),
        store: UserDefaultsVaultSetupStore(
            defaults: UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard))
    private static let identityConfirmer = VaultMacIdentityConfirmationPresenter()
    /// The host owns import implementation. The UI only exposes the seam.
    static var importHandler: (() -> Void)?

    static func install() {
        _ = setupCoordinator.load()
        _ = makeServices()
    }

    static func applicationDidEnterBackground() {
        syncRuntime?.applicationDidEnterBackground()
    }

    static func applicationWillEnterForeground() {
        syncRuntime?.applicationWillEnterForeground()
    }

    static func makeRootViewController() -> UIViewController {
        let root = VaultRootViewController(
            services: makeServices(), setupCoordinator: setupCoordinator,
            searchIndex: makeSearchIndex(), searchIndexProvider: makeSearchIndex,
            servicesProvider: makeServices, importHandler: importHandler)
        identityConfirmer.attach(to: root)
        return root
    }

    private static func makeServices() -> VaultRuntimeServices? {
        guard let policy = setupCoordinator.state.policy else {
            services = nil
            syncRuntime = nil
            return nil
        }
        if let services, services.policy == policy { return services }
        // A Settings policy change must rebuild the provider. Keeping the
        // previous device service here would make a newly-selected Mac or
        // iCloud location appear ready until the next process launch.
        services = nil
        syncRuntime = nil
        do {
            let value: VaultRuntimeServices
            if policy.location == .mac { value = try makeMacServices(policy: policy) }
            else { value = try VaultRuntimeServices.production(policy: policy) }
            services = value
            syncRuntime = VaultSyncRuntimeController(services: value)
            return value
        } catch {
            return nil
        }
    }

    private static func makeMacServices(policy: VaultStoragePolicy) throws -> VaultRuntimeServices {
        let accessGroup = Bundle.main.object(forInfoDictionaryKey: "LunaVaultKeychainAccessGroup") as? String
        guard let accessGroup, !accessGroup.isEmpty else { throw VaultMacProtocolError.unavailable }
        let rootKeys = VaultRootKeyManager(configuration:
            VaultCryptoConfiguration(keychainAccessGroup: accessGroup))
        let repository = try VaultRepository()
        let device = VaultDeviceBackend(store: repository)
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
        let sync: VaultSyncCoordinator?
        if let backend {
            let staging = repository.contentDirectory.deletingLastPathComponent()
                .appendingPathComponent("VaultSyncCiphertext", isDirectory: true)
            let payloadStore = try VaultFileSyncPayloadStore(
                rootURL: staging, vaultID: "default", repository: repository,
                rootKey: { try rootKeys.key(version: $0) })
            sync = VaultSyncCoordinator(repository: repository, backend: backend,
                payloadSource: payloadStore, owner: "iphone-mac-host",
                configuration: VaultSyncConfiguration(location: .mac))
        } else {
            sync = nil
        }
        return VaultRuntimeServices(
            policy: policy, repository: repository,
            deviceBackend: device, remoteBackend: backend, syncCoordinator: sync)
    }

    private static func makeSearchIndex() -> VaultSearchIndex? {
        guard let container = AppConfig.sharedContainerURL() else { return nil }
        return try? VaultSearchIndex(databaseURL: container.appendingPathComponent("vault-index.sqlite"))
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
