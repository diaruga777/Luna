import Foundation
import LunaVaultEmbeddings
import LunaVaultIndexExtraction

public struct VaultFakeTextExtractor: VaultTextExtracting, Sendable {
    public let result: VaultExtractedText

    public init(text: String) {
        result = VaultExtractedText(text: text)
    }

    public func extractText(from data: Data, contentType: String?) async throws -> VaultExtractedText {
        result
    }
}

public struct VaultFakeTranscriber: VaultTranscribing, Sendable {
    public let result: VaultExtractedText

    public init(transcript: String) {
        result = VaultExtractedText(text: transcript)
    }

    public func transcribeSpokenWords(from data: Data, contentType: String?) async throws -> VaultExtractedText {
        result
    }
}

public struct VaultFakeEmbedder: VaultEmbeddingGenerating, Sendable {
    public let result: VaultEmbedding

    public init(values: [Float], modelVersion: String = "vault-test-model-v1") {
        result = VaultEmbedding(values: values, modelVersion: modelVersion)
    }

    public func embedding(for text: String) async throws -> VaultEmbedding {
        result
    }
}
