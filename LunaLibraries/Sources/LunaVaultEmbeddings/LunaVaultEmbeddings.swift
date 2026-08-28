import Foundation
import CryptoKit
import LunaVaultModels

public enum LunaVaultEmbeddingsModule { public static let identifier = "LunaVaultEmbeddings" }

public enum VaultEmbeddingError: Error, Equatable, Sendable {
    case modelUnavailable(String)
    case invalidDimension(expected: Int, actual: Int)
    case invalidChecksum
    case emptyInput
}

public struct VaultEmbeddingModel: Codable, Equatable, Sendable {
    public let identifier: String
    public let version: String
    public let dimension: Int
    public init(identifier: String, version: String, dimension: Int) {
        self.identifier = identifier; self.version = version; self.dimension = max(1, dimension)
    }
}

public struct VaultEmbedding: Equatable, Codable, Sendable {
    public let values: [Float]
    public let modelVersion: String
    public let checksum: String

    public init(values: [Float], modelVersion: String, checksum: String? = nil) {
        self.values = values; self.modelVersion = modelVersion
        self.checksum = checksum ?? Self.checksum(for: values)
    }

    public var dimension: Int { values.count }
    public func validated(for model: VaultEmbeddingModel) throws -> VaultEmbedding {
        guard dimension == model.dimension else { throw VaultEmbeddingError.invalidDimension(expected: model.dimension, actual: dimension) }
        guard checksum == Self.checksum(for: values) else { throw VaultEmbeddingError.invalidChecksum }
        return self
    }

    public static func checksum(for values: [Float]) -> String {
        var bytes = Data(capacity: values.count * MemoryLayout<Float>.size)
        for value in values { var bitPattern = value.bitPattern.bigEndian; withUnsafeBytes(of: &bitPattern) { bytes.append(contentsOf: $0) } }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

public protocol VaultEmbeddingGenerating: Sendable {
    func embedding(for text: String) async throws -> VaultEmbedding
}

/// Core ML is intentionally an injected, bundled-model seam.  The v1 bundle
/// contains no model, so the default is explicit failure rather than a hidden
/// download or a remote inference fallback.
public struct UnavailableVaultEmbeddingGenerator: VaultEmbeddingGenerating {
    public let model: VaultEmbeddingModel
    public init(model: VaultEmbeddingModel = VaultEmbeddingModel(identifier: "vault-local", version: "unavailable", dimension: 1)) { self.model = model }
    public func embedding(for text: String) async throws -> VaultEmbedding {
        throw VaultEmbeddingError.modelUnavailable(model.identifier)
    }
}

/// A deterministic fixture generator for unit tests and migration tests.  It
/// is deliberately simple and is never selected by production composition.
public struct DeterministicVaultEmbeddingGenerator: VaultEmbeddingGenerating {
    public let model: VaultEmbeddingModel
    public init(model: VaultEmbeddingModel = VaultEmbeddingModel(identifier: "vault-test", version: "1", dimension: 16)) { self.model = model }
    public func embedding(for text: String) async throws -> VaultEmbedding {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw VaultEmbeddingError.emptyInput }
        let digest = Array(SHA256.hash(data: Data(text.precomposedStringWithCanonicalMapping.utf8)))
        var values: [Float] = []; values.reserveCapacity(model.dimension)
        for index in 0..<model.dimension {
            let byte = digest[index % digest.count]
            values.append((Float(byte) / 127.5) - 1.0)
        }
        let length = sqrt(values.reduce(Float.zero) { $0 + $1 * $1 })
        if length > 0 { values = values.map { $0 / length } }
        return VaultEmbedding(values: values, modelVersion: model.version)
    }
}
