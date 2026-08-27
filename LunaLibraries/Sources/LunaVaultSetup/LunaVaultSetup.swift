import Foundation
import LunaVaultBackend
import LunaVaultCrypto
import LunaVaultModels
import LunaVaultStorage

public enum LunaVaultSetupModule {
    public static let identifier = "LunaVaultSetup"
}

public struct VaultSetupConfiguration: Equatable, Sendable {
    public let backendIdentifier: String?

    public init(backendIdentifier: String? = nil) {
        self.backendIdentifier = backendIdentifier
    }
}
