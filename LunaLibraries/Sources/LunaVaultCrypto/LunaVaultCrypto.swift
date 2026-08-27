import Foundation
import LunaAppConfig
import LunaVaultModels

public enum LunaVaultCryptoModule {
    public static let identifier = "LunaVaultCrypto"
}

public struct VaultCryptoConfiguration: Equatable, Sendable {
    public let keychainAccessGroup: String

    public init(keychainAccessGroup: String) {
        self.keychainAccessGroup = keychainAccessGroup
    }
}

/// Narrow seam for the later synchronizable-Keychain implementation.
public protocol VaultKeyStoring: Sendable {
    func data(forKey key: String) throws -> Data?
    func setData(_ data: Data, forKey key: String) throws
    func removeData(forKey key: String) throws
}

/// Envelope operations remain injected until the encrypted format is specified.
public protocol VaultCrypting: Sendable {
    func seal(_ plaintext: Data) throws -> Data
    func open(_ ciphertext: Data) throws -> Data
}
