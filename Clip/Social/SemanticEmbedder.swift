//
//  SemanticEmbedder.swift
//  Clip
//

import Foundation
import NaturalLanguage

/// Turns article/video text into an on-device embedding vector using Apple's
/// Natural Language sentence embedding. MAIN APP ONLY — loading the NL model
/// costs memory, so this is never used in the App-Intent runner.
///
/// The model is loaded lazily and can be released between batches (`release()`)
/// to return its memory to the system.
final class SemanticEmbedder {

    /// Cap the text fed to the model so a long article doesn't blow up memory or
    /// time — the lead is the most topical part anyway.
    private static let maxCharacters = 1200

    private var embedding: NLEmbedding?

    /// The embedding vector for `text`, or nil if the model is unavailable or
    /// the text is empty. Vector dimension is whatever the model emits.
    func embed(_ text: String) -> [Float]? {
        let trimmed = String(text.prefix(Self.maxCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if embedding == nil { embedding = NLEmbedding.sentenceEmbedding(for: .english) }
        guard let vector = embedding?.vector(for: trimmed) else { return nil }
        return vector.map { Float($0) }
    }

    /// Releases the model's memory; call when a batch of embedding is done.
    func release() { embedding = nil }
}
