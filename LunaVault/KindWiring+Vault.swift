import Foundation
import UIKit
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultStorage
import LunaVaultSync
import LunaVaultUI

/// The composition seam for Luna Vault. The app owns construction of the
/// repository, root-key manager, and optional paired-Mac backend here. The
/// scene receives only the resulting runtime instead of locating services.
@MainActor enum VaultWiring {
    private static var services: VaultRuntimeServices?
    private static var syncRuntime: VaultSyncRuntimeController?
    private static var backgroundScheduler: VaultBackgroundTaskScheduler?
    private static var importCoordinator: VaultImportCoordinator?
    private static var indexWorker: VaultIndexWorker?
    private static var thumbnailStore: VaultThumbnailStore?
    private static let identityConfirmer = VaultMacIdentityConfirmationPresenter()

    static func install() { _ = makeServices() }

    static func applicationDidEnterBackground() {
        syncRuntime?.applicationDidEnterBackground()
        for kind in [VaultBackgroundTaskKind.importRepair, .index, .thumbnailMaintenance] {
            try? backgroundScheduler?.schedule(kind: kind)
        }
    }

    static func applicationWillEnterForeground() {
        syncRuntime?.applicationWillEnterForeground()
        _ = backgroundScheduler?.run(kind: .importRepair)
        _ = backgroundScheduler?.run(kind: .index)
    }

    static func makeRootViewController() -> UIViewController {
        let root = VaultRootViewController(services: makeServices())
        identityConfirmer.attach(to: root)
        return root
    }

    private static func makeServices() -> VaultRuntimeServices? {
        if let services { return services }
        let location = UserDefaults.standard.string(forKey: "LunaVault.storageLocation")
            .flatMap(VaultStorageLocation.init(rawValue:)) ?? .device
        do {
            let value: VaultRuntimeServices
            if location == .mac { value = try makeMacServices() }
            else { value = try VaultRuntimeServices.productionFromDefaults() }
            services = value
            syncRuntime = VaultSyncRuntimeController(services: value)
            installBackgroundRuntime(for: value)
            return value
        } catch {
            return nil
        }
    }

    /// Registers the local maintenance path at launch. It deliberately uses
    /// only repository, metadata, search, and thumbnail services; no backend
    /// or URLSession is constructed for import repair or indexing.
    private static func installBackgroundRuntime(for services: VaultRuntimeServices) {
        let root = services.repository.contentDirectory.deletingLastPathComponent()
        do {
            let metadata = try VaultImportedFileMetadataStore(
                rootURL: root.appendingPathComponent("VaultImportStaging/Metadata", isDirectory: true))
            let worker = VaultIndexWorker(
                repository: services.repository,
                metadataStore: metadata,
                searchIndex: try VaultSearchIndex(
                    databaseURL: root.appendingPathComponent("vault-index.sqlite")),
                owner: "vault-local-index")
            let thumbnails = try VaultThumbnailStore(
                rootURL: root.appendingPathComponent("VaultThumbnails", isDirectory: true),
                repository: services.repository)
            let coordinator = try VaultImportCoordinator(
                repository: services.repository, metadataStore: metadata)
            let scheduler = VaultBackgroundTaskScheduler(
                identifierPrefix: Bundle.main.bundleIdentifier ?? "com.hsanabria.luna.vault")
            scheduler.register(kind: .importRepair) { [weak coordinator] in
                guard let coordinator else { return false }
                return (try? coordinator.repairInterruptedImports()) != nil
            }
            scheduler.register(kind: .index) { [weak worker] in
                guard let worker else { return false }
                var processed = 0
                while !Task.isCancelled && processed < 64 {
                    guard await worker.processNext() != nil else { break }
                    processed += 1
                }
                return !Task.isCancelled
            }
            scheduler.register(kind: .thumbnailMaintenance) { [weak thumbnails] in
                guard let thumbnails else { return false }
                return (try? thumbnails.evictExpired()) != nil
            }
            for kind in [VaultBackgroundTaskKind.importRepair, .index, .thumbnailMaintenance] {
                try? scheduler.registerWithSystemScheduler(kind: kind)
            }
            importCoordinator = coordinator
            indexWorker = worker
            thumbnailStore = thumbnails
            backgroundScheduler = scheduler
        } catch {
            // Storage setup already fails closed. Keep the UI usable while
            // leaving maintenance unregistered until the next launch.
            backgroundScheduler = nil
        }
    }

    private static func makeMacServices() throws -> VaultRuntimeServices {
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
            policy: VaultStoragePolicy(location: .mac), repository: repository,
            deviceBackend: device, remoteBackend: backend, syncCoordinator: sync)
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
