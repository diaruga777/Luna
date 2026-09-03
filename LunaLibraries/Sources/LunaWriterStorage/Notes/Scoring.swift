import Foundation
import LunaWriterModels

/// Turns a typed phrase into an FTS5 MATCH expression.
///
/// Pen's shape, kept because it is what makes a half-typed "@" query useful:
/// tokens are letters and digits only, deduped, each quoted so no token can be
/// read as FTS5 syntax, and OR-joined so a hit needs only one of them. The last
/// token takes a `*` while the user is still typing it.
public enum FTSQuery {
    public static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var seen = Set<String>()
        var current = ""
        for character in text.lowercased() {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else if !current.isEmpty {
                if seen.insert(current).inserted { tokens.append(current) }
                current = ""
            }
        }
        if !current.isEmpty, seen.insert(current).inserted { tokens.append(current) }
        return tokens
    }

    public static func make(_ text: String, prefixMatchesLastToken: Bool) -> String? {
        let tokens = tokens(text)
        guard !tokens.isEmpty else { return nil }
        return tokens.enumerated().map { index, token in
            let quoted = "\"\(token)\""
            let isLast = index == tokens.count - 1
            return isLast && prefixMatchesLastToken ? quoted + "*" : quoted
        }.joined(separator: " OR ")
    }
}

/// Pen's fusion, made local: three quarters of the answer is how close the
/// meanings are, one quarter is how well the words matched.
///
/// The cosine band is Pen's too. `NLEmbedding` sentence vectors of unrelated
/// English text sit near 0.10 and closely related text near 0.50, so the raw
/// cosine is rescaled from that band before it is weighed — otherwise every
/// pair scores "somewhat similar" and the threshold has nothing to bite on.
public enum HybridScorer {
    public static let cosineFloor = 0.10
    public static let cosineCeiling = 0.50
    public static let cosineWeight = 0.75
    public static let lexicalWeight = 0.25

    /// bm25 strength at which the lexical term is worth half a point.
    static let lexicalMidpoint = 1.0
    static let lexicalSteepness = 0.5

    public static func rescale(cosine: Double) -> Double {
        guard cosine.isFinite else { return 0 }
        let scaled = (cosine - cosineFloor) / (cosineCeiling - cosineFloor)
        return min(1, max(0, scaled))
    }

    /// FTS5's `bm25()` is ordered ascending — a more negative value is a better
    /// match — so it is flipped, then squashed into 0…1 by a logistic. Squashed
    /// rather than normalised because the raw value's scale moves with the
    /// corpus, and the fused score is compared against a fixed threshold.
    public static func lexical(bm25Rank: Double) -> Double {
        guard bm25Rank.isFinite else { return 0 }
        let strength = max(0, -bm25Rank)
        return 1 / (1 + exp(-(strength - lexicalMidpoint) / lexicalSteepness))
    }

    public static func fuse(cosine: Double, bm25Rank: Double) -> Double {
        cosineWeight * rescale(cosine: cosine) + lexicalWeight * lexical(bm25Rank: bm25Rank)
    }
}

/// Float32 vectors as BLOBs, and the cosine over them. No ANN: a library holds
/// a few thousand notes, and a linear pass over that is well under a frame.
enum VectorBlob {
    static func encode(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    static func decode(_ data: Data?, count: Int) -> [Float]? {
        guard count > 0, let data, data.count == count * MemoryLayout<Float>.size else { return nil }
        // `bindMemory` requires the buffer to be aligned for `Float`, which a
        // `Data` sliced from a larger blob is not guaranteed to be.
        // `loadUnaligned` reads byte-by-byte instead.
        let values = data.withUnsafeBytes { raw in
            (0..<count).map { index in
                raw.loadUnaligned(fromByteOffset: index * MemoryLayout<Float>.stride, as: Float.self)
            }
        }
        return values.allSatisfy(\.isFinite) ? values : nil
    }

    static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Double {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return 0 }
        var dot = 0.0, leftMagnitude = 0.0, rightMagnitude = 0.0
        for index in lhs.indices {
            let left = Double(lhs[index]), right = Double(rhs[index])
            dot += left * right
            leftMagnitude += left * left
            rightMagnitude += right * right
        }
        guard dot.isFinite, leftMagnitude > 0, rightMagnitude > 0 else { return 0 }
        let result = dot / (sqrt(leftMagnitude) * sqrt(rightMagnitude))
        return result.isFinite ? min(1, max(-1, result)) : 0
    }
}
