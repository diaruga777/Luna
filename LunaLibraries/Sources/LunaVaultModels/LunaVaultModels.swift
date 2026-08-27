import Foundation

public enum LunaVaultModelsModule {
    public static let identifier = "LunaVaultModels"
}

/// Opaque identity shared by Vault tiers. It intentionally carries no path,
/// filename, provider key or other remotely observable metadata.
public struct VaultObjectID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }
}

public protocol VaultClock: Sendable {
    func now() -> Date
}

public protocol VaultUUIDGenerating: Sendable {
    func next() -> UUID
}

public protocol VaultRandomBytesGenerating: Sendable {
    func bytes(count: Int) throws -> Data
}

public enum VaultScaffoldError: Error, Equatable, Sendable {
    case invalidByteCount(Int)
    case missingValue(String)
    case noEgress(URL)
}
