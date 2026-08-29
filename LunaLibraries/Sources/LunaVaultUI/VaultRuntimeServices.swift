import Foundation
import LunaAppConfig
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultStorage
import LunaVaultSync
import LunaVaultSetup

public enum VaultRuntimeError: Error, Sendable { case unsupportedLocation, providerUnavailable }

/// App-host composition for the v1 file backends. The Share extension never
/// links or constructs this type, preserving its keyless handoff boundary.
public final class VaultRuntimeServices: @unchecked Sendable {
    public let policy: VaultStoragePolicy
    public let repository: VaultRepository
    public let deviceBackend: VaultDeviceBackend
    public let remoteBackend: VaultBackendTransport?
    public let syncCoordinator: VaultSyncCoordinator?
    /// The app-owned encryption policy used when a document import also
    /// schedules a remote upload. Extensions never receive this capability.
    public let remoteImportConfiguration: VaultImportRemoteConfiguration?
    /// The selected remote backend key is retained even while its credential
    /// is missing or revoked. A non-nil key with no configuration is an
    /// explicit unavailable-remote selection; import must fail closed instead
    /// of silently falling back to device-only storage.
    public let remoteImportBackendKey: String?
    /// The import capsule consumed by the app-owned coordinator. Keeping the
    /// unavailable selection in this value makes the downgrade guard a single
    /// composition-root invariant shared by foreground and repair paths.
    public var importConfiguration: VaultImportConfiguration {
        VaultImportConfiguration(uploadBackendKey: remoteImportBackendKey ??
                                 remoteImportConfiguration?.backendKey,
                                 remote: remoteImportConfiguration)
    }
    public var availability: VaultBackendAvailability {
        remoteBackend?.currentAvailability ?? (policy.location == .device ? .available : .unavailable)
    }
    public var isReady: Bool {
        availability == .available
    }

    public init(policy: VaultStoragePolicy,
                repository: VaultRepository,
                deviceBackend: VaultDeviceBackend,
                remoteBackend: VaultBackendTransport?,
                syncCoordinator: VaultSyncCoordinator?,
                remoteImportConfiguration: VaultImportRemoteConfiguration? = nil,
                remoteImportBackendKey: String? = nil) {
        self.policy = policy; self.repository = repository
        self.deviceBackend = deviceBackend; self.remoteBackend = remoteBackend
        self.syncCoordinator = syncCoordinator
        self.remoteImportConfiguration = remoteImportConfiguration
        self.remoteImportBackendKey = remoteImportBackendKey
    }

    public static func production(policy: VaultStoragePolicy) throws -> VaultRuntimeServices {
        let storage = VaultStorageConfiguration(
            databaseName: AppConfig.vaultDatabaseName, policy: policy)
        let repository = try VaultRepository(configuration: storage)
        let device = VaultDeviceBackend(store: repository)
        guard policy.location == .iCloud else {
            if policy.location == .device {
                return VaultRuntimeServices(policy: policy, repository: repository,
                                            deviceBackend: device, remoteBackend: nil,
                                            syncCoordinator: nil,
                                            remoteImportConfiguration: nil)
            }
            throw VaultRuntimeError.unsupportedLocation
        }
        let backend = VaultICloudBackend(configuration: VaultICloudBackendConfiguration(
            containerIdentifier: AppConfig.vaultICloudContainerID,
            keepLocalCopy: policy.keepLocalCopy))
        guard backend.currentAvailability == .available else {
            throw VaultRuntimeError.providerUnavailable
        }
        let staging = repository.contentDirectory.deletingLastPathComponent()
            .appendingPathComponent("VaultSyncCiphertext", isDirectory: true)
        guard let keychainAccessGroup = AppConfig.vaultKeychainAccessGroup else {
            throw VaultRuntimeError.unsupportedLocation
        }
        let keyManager = VaultRootKeyManager(configuration: VaultCryptoConfiguration(
            keychainAccessGroup: keychainAccessGroup, vaultID: "default"))
        let currentRoot = try keyManager.loadOrCreate()
        let payloadStore = try VaultFileSyncPayloadStore(
            rootURL: staging, vaultID: "default", repository: repository,
            rootKey: { try keyManager.key(version: $0) })
        let sync = VaultSyncCoordinator(repository: repository, backend: backend,
                                        payloadSource: payloadStore,
                                        owner: "iphone-host")
        return VaultRuntimeServices(policy: policy, repository: repository,
                                    deviceBackend: device, remoteBackend: backend,
                                    syncCoordinator: sync,
                                    remoteImportConfiguration: VaultImportRemoteConfiguration(
                                        backendKey: backend.identity.stableKey, vaultID: "default",
                                        root: currentRoot,
                                        rootKey: { try keyManager.key(version: $0) },
                                        payloadDirectory: staging.appendingPathComponent("uploads", isDirectory: true)))
    }

    public static func productionFromDefaults(_ defaults: UserDefaults = .standard) throws -> VaultRuntimeServices {
        let location = defaults.string(forKey: "LunaVault.storageLocation")
            .flatMap(VaultStorageLocation.init(rawValue:)) ?? .device
        let keepLocal = defaults.object(forKey: "LunaVault.keepLocalCopy") as? Bool ?? true
        return try production(policy: VaultStoragePolicy(location: location, keepLocalCopy: keepLocal))
    }
}
