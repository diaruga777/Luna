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

public enum VaultKeyAccessibility: String, Codable, Sendable {
    case afterFirstUnlock
    case whenUnlocked
}

/// Complete Keychain identity for one Vault key. Tests retain these fields so
/// access-group, synchronizable, and accessibility regressions cannot hide
/// behind a single dictionary key.
public struct VaultKeyDescriptor: Codable, Hashable, Sendable {
    public let service: String
    public let account: String
    public let accessGroup: String
    public let synchronizable: Bool
    public let accessibility: VaultKeyAccessibility

    public init(
        service: String,
        account: String,
        accessGroup: String,
        synchronizable: Bool,
        accessibility: VaultKeyAccessibility
    ) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
        self.synchronizable = synchronizable
        self.accessibility = accessibility
    }
}

/// Narrow seam for the later synchronizable-Keychain implementation. The
/// production key store will use the Vault access group and kSecAttrSynchronizable;
/// test implementations must never substitute the user's real Keychain.
public protocol VaultKeyStoring: Sendable {
    func data(for descriptor: VaultKeyDescriptor) throws -> Data?
    func setData(_ data: Data, for descriptor: VaultKeyDescriptor) throws
    func removeData(for descriptor: VaultKeyDescriptor) throws
}

/// Envelope operations remain injected until the encrypted format is specified.
/// Implementations must authenticate ciphertext before returning plaintext.
public protocol VaultCrypting: Sendable {
    func seal(_ plaintext: Data) throws -> Data
    func open(_ ciphertext: Data) throws -> Data
}
