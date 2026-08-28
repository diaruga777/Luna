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

    public var dimension: Int { values.count }

    /// A normalized copy suitable for cosine search. Zero vectors remain zero.
    public var normalized: VaultEmbedding {
        let magnitude = sqrt(values.reduce(Float(0)) { $0 + ($1 * $1) })
        guard magnitude > 0 else { return self }
        return VaultEmbedding(values: values.map { $0 / magnitude }, modelVersion: modelVersion)
    }
}

public enum VaultEmbeddingError: Error, Equatable, Sendable {
    case emptyModelVersion
    case emptyVector
    case nonFiniteValue
}

public extension VaultEmbedding {
    func validated() throws -> VaultEmbedding {
        guard !modelVersion.isEmpty else { throw VaultEmbeddingError.emptyModelVersion }
        guard !values.isEmpty else { throw VaultEmbeddingError.emptyVector }
        guard values.allSatisfy({ $0.isFinite }) else { throw VaultEmbeddingError.nonFiniteValue }
        return self
    }
}

public protocol VaultEmbeddingGenerating: Sendable {
    func embedding(for text: String) async throws -> VaultEmbedding
}
