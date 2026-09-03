import Foundation
import LunaWriterModels
import NaturalLanguage

/// The seam the index scores meaning through. Production is `NLEmbedding`;
/// a test installs its own so a score is a fact rather than a model's mood.
public protocol SentenceEmbedding: AnyObject {
    var modelVersion: String { get }
    var dimensions: Int { get }
    func vector(for text: String) -> [Float]?
}

/// Apple's on-device sentence embedding. `init?` returns nil where the model
/// is missing for the language, and the index then runs on FTS alone.
public final class NLSentenceEmbedding: SentenceEmbedding {
    private let embedding: NLEmbedding
    public let modelVersion: String
    public var dimensions: Int { embedding.dimension }

    public init?(language: NLLanguage = .english) {
        guard let embedding = NLEmbedding.sentenceEmbedding(for: language) else { return nil }
        self.embedding = embedding
        self.modelVersion = "nl-sentence-\(language.rawValue)-\(embedding.revision)"
    }

    public func vector(for text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let values = embedding.vector(for: trimmed) else { return nil }
        let floats = values.map(Float.init)
        return floats.allSatisfy(\.isFinite) ? floats : nil
    }
}
