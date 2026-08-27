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

    public init(allowsCellularAccess: Bool = true) {
        self.allowsCellularAccess = allowsCellularAccess
    }
}
