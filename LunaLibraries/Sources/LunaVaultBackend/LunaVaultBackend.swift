import Foundation
import LunaVaultCrypto
import LunaVaultModels

public enum LunaVaultBackendModule {
    public static let identifier = "LunaVaultBackend"
}

/// Tailscale is an optional transport path for the user's paired Mac. The
/// app still authenticates the Mac and encrypts every protocol message; a
/// Tailscale IP or MagicDNS name is never treated as identity or storage.
public struct VaultMacConnectionConfiguration: Equatable, Sendable {
    public let endpoint: String
    public let port: UInt16
    public let usesTailscale: Bool

    public init(endpoint: String, port: UInt16, usesTailscale: Bool = true) {
        self.endpoint = endpoint
        self.port = port
        self.usesTailscale = usesTailscale
    }
}

/// Opaque, already-encrypted payload transport. Device, iCloud, and Mac
/// adapters arrive in a later stage and must never receive plaintext names,
/// metadata or file bytes. Cloud-provider-specific adapters are intentionally
/// out of the v1 contract.
public protocol VaultBackendTransport: Sendable {
    func putCiphertext(_ ciphertext: Data, for id: VaultObjectID) async throws
    func ciphertext(for id: VaultObjectID) async throws -> Data?
    func removeCiphertext(for id: VaultObjectID) async throws
}

public struct VaultBackendConfiguration: Equatable, Sendable {
    public let location: VaultStorageLocation
    public let macConnection: VaultMacConnectionConfiguration?

    public init(location: VaultStorageLocation, macConnection: VaultMacConnectionConfiguration? = nil) {
        self.location = location
        self.macConnection = location == .mac ? macConnection : nil
    }
}
