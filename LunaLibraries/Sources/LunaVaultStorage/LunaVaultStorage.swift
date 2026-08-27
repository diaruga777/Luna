import Foundation
import LunaAppConfig
import LunaVaultCrypto
import LunaVaultModels

public enum LunaVaultStorageModule {
    public static let identifier = "LunaVaultStorage"
}

public struct VaultStorageConfiguration: Equatable, Sendable {
    public let databaseName: String

    public init(databaseName: String = "vault.sqlite") {
        self.databaseName = databaseName
    }
}

/// A minimal persistence seam; the Stage 1 scaffold has no database owner.
public protocol VaultObjectStoring: Sendable {
    func data(for id: VaultObjectID) throws -> Data?
    func setData(_ data: Data, for id: VaultObjectID) throws
    func removeData(for id: VaultObjectID) throws
}
