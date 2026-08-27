import Foundation
import LunaVaultModels

public enum LunaVaultIndexExtractionModule {
    public static let identifier = "LunaVaultIndexExtraction"
}

public struct VaultExtractedText: Equatable, Sendable {
    public let text: String

    public init(text: String) {
        self.text = text
    }
}

public protocol VaultTextExtracting: Sendable {
    func extractText(from data: Data, contentType: String?) async throws -> VaultExtractedText
}

public protocol VaultTranscribing: Sendable {
    func transcribeSpokenWords(from data: Data, contentType: String?) async throws -> VaultExtractedText
}
