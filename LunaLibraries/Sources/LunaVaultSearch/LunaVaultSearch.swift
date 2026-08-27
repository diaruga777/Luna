import Foundation
import LunaVaultEmbeddings
import LunaVaultIndexExtraction
import LunaVaultModels
import LunaVaultStorage

public enum LunaVaultSearchModule {
    public static let identifier = "LunaVaultSearch"
}

public struct VaultSearchConfiguration: Equatable, Sendable {
    public let maximumResults: Int

    public init(maximumResults: Int = 50) {
        self.maximumResults = maximumResults
    }
}

public protocol VaultSearching: Sendable {
    func matchingObjectIDs(for query: String) async throws -> [VaultObjectID]
}
