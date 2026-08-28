import Foundation
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultStorage

public enum LunaVaultSyncModule {
    public static let identifier = "LunaVaultSync"
}

public struct VaultSyncConfiguration: Equatable, Sendable {
    public let allowsCellularAccess: Bool
    public let location: VaultStorageLocation

    public init(
        allowsCellularAccess: Bool = true,
        location: VaultStorageLocation = .device
    ) {
        self.allowsCellularAccess = allowsCellularAccess
        self.location = location
    }
}
