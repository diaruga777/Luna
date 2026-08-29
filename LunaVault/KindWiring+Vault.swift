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
    /// Bumps on explicit credential lifecycle changes. This keeps a save of
    /// an otherwise identical credential from reusing a live backend actor.
    private static var runtimeGeneration: UInt64 = 0
    private static let setupCoordinator = VaultSetupCoordinator(
        configuration: VaultSetupConfiguration(
            keychainAccessGroup: Bundle.main.object(forInfoDictionaryKey: "LunaVaultKeychainAccessGroup") as? String),
        store: UserDefaultsVaultSetupStore(
            defaults: UserDefaults(suiteName: AppConfig.appGroupID) ?? .standard))
    private static var backgroundScheduler: VaultBackgroundTaskScheduler?
    private static var importCoordinator: VaultImportCoordinator?
    private static var indexWorker: VaultIndexWorker?
    private static var thumbnailStore: VaultThumbnailStore?
    private static let identityConfirmer = VaultMacIdentityConfirmationPresenter()
    /// The host owns import implementation. The UI only exposes the seam.
    static var importHandler: (() -> Void)?
    /// The host owns preview/rendering. The UI only forwards canonical IDs.
    static var openHandler: ((VaultObjectID) -> Void)?
    /// Optional host handoff for the one-use enrollment material. The UI also
    /// keeps a visible copy/share/export affordance for the user.
    static var enrollmentPreparedHandler: ((VaultMacPairingEnrollment) -> Void)?
    static var storagePolicyChangedHandler: ((VaultStoragePolicy) -> Void)?
    static var credentialSavedHandler: ((VaultMacPairingCredential) -> Void)?
    static var credentialUnpairedHandler: ((VaultMacRemoteRevocationOutcome) -> Void)?

    static func install() {
        _ = setupCoordinator.load()
        _ = makeServices()
    }

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
        // Index/storage construction is intentionally deferred until setup is
        // ready. The provider callbacks let the root lazily recover after a
        // first-run completion or a transient provider failure.
        let index = setupCoordinator.state.isReady ? makeSearchIndex() : nil
        let root = VaultRootViewController(
            services: makeServices(), setupCoordinator: setupCoordinator,
            searchIndex: index, searchIndexProvider: makeSearchIndex,
            servicesProvider: makeServices, importHandler: importHandler,
            openHandler: openHandler, settingsActions: makeSettingsActions())
        identityConfirmer.attach(to: root)
        return root
    }

    private static func makeSettingsActions() -> VaultSettingsActions {
        VaultSettingsActions(
            storagePolicyChanged: { storagePolicyChangedHandler?($0) },
            clearCache: {
                guard let value = services ?? makeServices() else {
                    throw VaultRuntimeError.providerUnavailable
                }
                try value.repository.evictExpired()
            },
            rebuildIndex: {
                guard let index = makeSearchIndex() else {
                    throw VaultSearchError.sqlite("Vault index is unavailable")
                }
                try index.rebuild()
            },
            // Eviction is an object-scoped backend operation. Settings keeps
            // this callback honest until a file-level picker is presented;
            // it must never claim that a local copy was removed.
            requestICloudEviction: { .unavailable },
            reconfigureRuntime: {
                invalidateRuntime()
                _ = makeServices()
            },
            enrollmentPrepared: { enrollmentPreparedHandler?($0) },
            credentialSaved: { credentialSavedHandler?($0) },
            revokeMacCredential: { _ in
                // Vault's wire protocol has no unauthenticated revoke call.
                // Drop the local runtime immediately; the UI reports the
                // remote operation as local-only and instructs the user to
                // revoke the companion before pairing again.
                invalidateRuntime()
                return .localOnly(reason: "The paired Mac must be revoked from its companion process.")
            },
            credentialUnpaired: { credentialUnpairedHandler?($0) }
        )
    }

    private static func makeServices() -> VaultRuntimeServices? {
        guard let policy = setupCoordinator.state.policy else {
            services = nil
            syncRuntime = nil
            return nil
        }
        let credential: VaultMacPairingCredential?
        do {
            credential = policy.location == .mac ? try loadMacCredential() : nil
        } catch {
            services = nil
            syncRuntime = nil
            return nil
        }
        let runtimeIdentity = makeRuntimeIdentity(policy: policy, credential: credential)
        if let services, services.runtimeIdentity == runtimeIdentity { return services }
        // A Settings policy or credential change must rebuild the provider.
        // Keeping the previous service here would make a newly-selected Mac
        // or credential appear ready until the next process launch.
        services = nil
        syncRuntime = nil
        do {
            let value: VaultRuntimeServices
            if policy.location == .mac {
                value = try makeMacServices(policy: policy, credential: credential,
                    runtimeIdentity: runtimeIdentity)
            }
            else {
                value = try VaultRuntimeServices.production(policy: policy,
                    runtimeIdentity: runtimeIdentity)
            }
            services = value
            syncRuntime = VaultSyncRuntimeController(services: value)
            installBackgroundRuntime(for: value)
            return value
        } catch {
            return nil
        }
    }

    private static func invalidateRuntime() {
        runtimeGeneration &+= 1
        services = nil
        syncRuntime = nil
    }

    private static func loadMacCredential() throws -> VaultMacPairingCredential? {
        guard let accessGroup = Bundle.main.object(forInfoDictionaryKey: "LunaVaultKeychainAccessGroup") as? String,
              !accessGroup.isEmpty else { throw VaultMacProtocolError.unavailable }
        let store = VaultMacKeychainCredentialStore(accessGroup: accessGroup,
            service: "\(Bundle.main.bundleIdentifier ?? "com.hsanabria.luna.vault").mac-pairing")
        return try store.load()
    }

    private static func makeRuntimeIdentity(policy: VaultStoragePolicy,
                                             credential: VaultMacPairingCredential?) -> VaultRuntimeIdentity {
        let backendIdentity: VaultBackendIdentity?
        switch policy.location {
        case .device:
            backendIdentity = nil
        case .iCloud:
            backendIdentity = VaultBackendIdentity(location: .iCloud,
                containerIdentifier: AppConfig.vaultICloudContainerID, vaultID: "default")
        case .mac:
            backendIdentity = credential.map {
                VaultBackendIdentity(location: .mac,
                    containerIdentifier: $0.endpointBinding, vaultID: "default")
            }
        }
        return VaultRuntimeIdentity(policy: policy, backendIdentity: backendIdentity,
            credentialGeneration: credential?.epoch,
            credentialFingerprint: credential?.fingerprint,
            runtimeGeneration: runtimeGeneration)
    }

    private static func makeMacServices(policy: VaultStoragePolicy,
                                        credential: VaultMacPairingCredential?,
                                        runtimeIdentity: VaultRuntimeIdentity) throws -> VaultRuntimeServices {
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

    private static func makeMacServices(policy: VaultStoragePolicy,
                                        credential: VaultMacPairingCredential?,
                                        runtimeIdentity: VaultRuntimeIdentity) throws -> VaultRuntimeServices {
        let accessGroup = Bundle.main.object(forInfoDictionaryKey: "LunaVaultKeychainAccessGroup") as? String
        guard let accessGroup, !accessGroup.isEmpty else { throw VaultMacProtocolError.unavailable }
        let rootKeys = VaultRootKeyManager(configuration:
            VaultCryptoConfiguration(keychainAccessGroup: accessGroup))
        let repository = try VaultRepository()
        let device = VaultDeviceBackend(store: repository)
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
            deviceBackend: device, remoteBackend: backend, syncCoordinator: sync,
            runtimeIdentity: runtimeIdentity)
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
                        _ = self.lock.withLock {
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
