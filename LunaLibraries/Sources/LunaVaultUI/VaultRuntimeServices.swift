import Foundation
import LunaAppConfig
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultStorage
import LunaVaultSync

public enum VaultRuntimeError: Error, Sendable { case unsupportedLocation }

/// App-host composition for the v1 file backends. The Share extension never
/// links or constructs this type, preserving its keyless handoff boundary.
public final class VaultRuntimeServices: @unchecked Sendable {
    public let policy: VaultStoragePolicy
    public let repository: VaultRepository
    public let deviceBackend: VaultDeviceBackend
    public let remoteBackend: VaultBackendTransport?
    public let syncCoordinator: VaultSyncCoordinator?

    public init(policy: VaultStoragePolicy,
                repository: VaultRepository,
                deviceBackend: VaultDeviceBackend,
                remoteBackend: VaultBackendTransport?,
                syncCoordinator: VaultSyncCoordinator?) {
        self.policy = policy; self.repository = repository
        self.deviceBackend = deviceBackend; self.remoteBackend = remoteBackend
        self.syncCoordinator = syncCoordinator
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
                                            syncCoordinator: nil)
            }
            throw VaultRuntimeError.unsupportedLocation
        }
        let backend = VaultICloudBackend(configuration: VaultICloudBackendConfiguration(
            containerIdentifier: AppConfig.vaultICloudContainerID,
            keepLocalCopy: policy.keepLocalCopy))
        let staging = repository.contentDirectory.deletingLastPathComponent()
            .appendingPathComponent("VaultSyncCiphertext", isDirectory: true)
        guard let keychainAccessGroup = AppConfig.vaultKeychainAccessGroup else {
            throw VaultRuntimeError.unsupportedLocation
        }
        let keyManager = VaultRootKeyManager(configuration: VaultCryptoConfiguration(
            keychainAccessGroup: keychainAccessGroup, vaultID: "default"))
        let payloadStore = try VaultFileSyncPayloadStore(
            rootURL: staging, vaultID: "default",
            rootKey: { try keyManager.key(version: $0) })
        let sync = VaultSyncCoordinator(repository: repository, backend: backend,
                                        payloadSource: payloadStore,
                                        owner: "iphone-host")
        return VaultRuntimeServices(policy: policy, repository: repository,
                                    deviceBackend: device, remoteBackend: backend,
                                    syncCoordinator: sync)
    }

    public static func productionFromDefaults(_ defaults: UserDefaults = .standard) throws -> VaultRuntimeServices {
        let location = defaults.string(forKey: "LunaVault.storageLocation")
            .flatMap(VaultStorageLocation.init(rawValue:)) ?? .device
        let keepLocal = defaults.object(forKey: "LunaVault.keepLocalCopy") as? Bool ?? true
        return try production(policy: VaultStoragePolicy(location: location, keepLocalCopy: keepLocal))
    }
}
