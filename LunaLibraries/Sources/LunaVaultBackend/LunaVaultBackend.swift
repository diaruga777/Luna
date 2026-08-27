import Foundation
import LunaVaultCrypto
import LunaVaultModels

public enum LunaVaultBackendModule {
    public static let identifier = "LunaVaultBackend"
}

/// Opaque, already-encrypted payload transport. Provider adapters arrive in a
/// later stage and must never receive plaintext names, metadata or file bytes.
public protocol VaultBackendTransport: Sendable {
    func putCiphertext(_ ciphertext: Data, for id: VaultObjectID) async throws
    func ciphertext(for id: VaultObjectID) async throws -> Data?
    func removeCiphertext(for id: VaultObjectID) async throws
}

public struct VaultBackendConfiguration: Equatable, Sendable {
    public let identifier: String

    public init(identifier: String) {
        self.identifier = identifier
    }
}
