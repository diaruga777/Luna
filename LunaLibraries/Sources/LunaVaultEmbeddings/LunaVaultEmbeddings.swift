import Foundation
import LunaVaultModels

public enum LunaVaultEmbeddingsModule {
    public static let identifier = "LunaVaultEmbeddings"
}

public struct VaultEmbedding: Equatable, Sendable {
    public let values: [Float]
    public let modelVersion: String

    public init(values: [Float], modelVersion: String) {
        self.values = values
        self.modelVersion = modelVersion
    }
}

public protocol VaultEmbeddingGenerating: Sendable {
    func embedding(for text: String) async throws -> VaultEmbedding
}
