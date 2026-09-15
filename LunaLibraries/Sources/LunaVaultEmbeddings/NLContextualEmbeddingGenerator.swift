import Foundation

#if canImport(NaturalLanguage)
import NaturalLanguage
#endif

/// Uses Apple's on-device sentence embedding when the OS ships a contextual
/// model. No network model download is attempted; unavailable models fail
/// explicitly and the nightly worker leaves the file dirty for a later run.
public final class NLContextualEmbeddingGenerator: VaultEmbeddingGenerating, @unchecked Sendable {
    public let model: VaultEmbeddingModel
#if canImport(NaturalLanguage)
    private let sentenceEmbedding: NLEmbedding?
#endif

    public init(language: String = "en") {
#if canImport(NaturalLanguage)
        let language = NLLanguage(rawValue: language)
        sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: language)
        if let sentenceEmbedding {
            model = VaultEmbeddingModel(identifier: "NaturalLanguage.sentence.\(language.rawValue)",
                                        version: "system-\(sentenceEmbedding.dimension)",
                                        dimension: sentenceEmbedding.dimension)
        } else {
            model = VaultEmbeddingModel(identifier: "NaturalLanguage.unavailable", version: "unavailable", dimension: 1)
        }
#else
        model = VaultEmbeddingModel(identifier: "NaturalLanguage.unavailable", version: "unavailable", dimension: 1)
#endif
    }

    public func embedding(for text: String) async throws -> VaultEmbedding {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VaultEmbeddingError.emptyInput
        }
#if canImport(NaturalLanguage)
        guard let sentenceEmbedding, let values = sentenceEmbedding.vector(for: text) else {
            throw VaultEmbeddingError.modelUnavailable(model.identifier)
        }
        return VaultEmbedding(values: values.map(Float.init), modelVersion: model.version,
                              modelChecksum: model.checksum).normalized
#else
        throw VaultEmbeddingError.modelUnavailable(model.identifier)
#endif
    }
}
