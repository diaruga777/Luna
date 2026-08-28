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

/// The only storage locations supported by the first Vault release. Provider
/// names deliberately do not appear in the public model: Vault is a gateway
/// to user-owned device, iCloud, or Mac storage, not a cloud-provider catalog.
public enum VaultStorageLocation: String, Codable, CaseIterable, Sendable {
    case device
    case iCloud
    case mac
}

/// iCloud can retain the canonical copy while the local working copy is
/// evicted. `keepLocalCopy` is a policy, not a second backend.
public struct VaultStoragePolicy: Codable, Equatable, Sendable {
    public let location: VaultStorageLocation
    public let keepLocalCopy: Bool

    public init(location: VaultStorageLocation, keepLocalCopy: Bool = true) {
        self.location = location
        self.keepLocalCopy = location == .iCloud ? keepLocalCopy : true
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
