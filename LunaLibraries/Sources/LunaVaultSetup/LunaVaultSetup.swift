import Foundation
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultStorage

public enum LunaVaultSetupModule {
    public static let identifier = "LunaVaultSetup"
}

public struct VaultSetupConfiguration: Equatable, Sendable {
    public let storagePolicy: VaultStoragePolicy?

    public init(storagePolicy: VaultStoragePolicy? = nil) {
        self.storagePolicy = storagePolicy
    }
}
