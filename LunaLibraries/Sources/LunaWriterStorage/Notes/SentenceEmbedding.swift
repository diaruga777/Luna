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

/// Apple's on-device sentence embedding. The model loads on first use
/// rather than at construction, so building the storage stack never touches
/// NaturalLanguage. Where the language has no model, `dimensions` is 0 and
/// `vector(for:)` is nil, and the index then runs on FTS alone.
public final class NLSentenceEmbedding: SentenceEmbedding {
    private let language: NLLanguage
    /// How the model is loaded. Production calls `NLEmbedding` directly; a
    /// test substitutes a counting fake to prove the load stays lazy.
    private let loader: (NLLanguage) -> NLEmbedding?
    /// `NLEmbedding.vector(for:)`'s thread safety is undocumented, and this
    /// tier calls it from the database queue, the editor's mention lookup and
    /// the router — all different threads. One queue serialises every call,
    /// including the model load, so the load happens exactly once.
    private let queue = DispatchQueue(label: "com.hsanabria.luna.writerSentenceEmbedding")
    private var resolved: Resolved?

    private struct Resolved {
        let embedding: NLEmbedding?
        let modelVersion: String
    }

    public convenience init(language: NLLanguage = .english) {
        self.init(language: language, loader: NLEmbedding.sentenceEmbedding(for:))
    }

    init(language: NLLanguage, loader: @escaping (NLLanguage) -> NLEmbedding?) {
        self.language = language
        self.loader = loader
    }

    public var modelVersion: String { queue.sync { resolve().modelVersion } }
    public var dimensions: Int { queue.sync { resolve().embedding?.dimension ?? 0 } }

    public func vector(for text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return queue.sync {
            guard let embedding = resolve().embedding, let values = embedding.vector(for: trimmed) else {
                return nil
            }
            let floats = values.map(Float.init)
            return floats.allSatisfy(\.isFinite) ? floats : nil
        }
    }

    /// Loads the model, if the language has one, and caches the result.
    /// Runs on `queue`, so concurrent callers share one load.
    private func resolve() -> Resolved {
        if let resolved { return resolved }
        let embedding = loader(language)
        let version = embedding.map { "nl-sentence-\(language.rawValue)-\($0.revision)" }
            ?? "nl-sentence-\(language.rawValue)-unavailable"
        let resolved = Resolved(embedding: embedding, modelVersion: version)
        self.resolved = resolved
        return resolved
    }
}
