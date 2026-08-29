import Foundation
import LunaVaultEmbeddings
import LunaVaultModels

/// A UI-facing search seam. The index already performs lexical/vector
/// candidate bounding; this facade owns the last presentation rule: one row
/// per canonical object while retaining the winning snippet, matched fields,
/// and symbolic-alias provenance.
public protocol VaultSearchPresenting: Sendable {
    func search(_ query: String, embedding: VaultEmbedding?, limit: Int) throws -> [VaultSearchHit]
    func recent(limit: Int) throws -> [VaultSearchHit]
}

public final class VaultSearchPresentationFacade: VaultSearchPresenting, @unchecked Sendable {
    public let index: VaultSearchIndex

    public init(index: VaultSearchIndex) { self.index = index }

    public func search(_ query: String, embedding: VaultEmbedding? = nil,
                       limit: Int = 50) throws -> [VaultSearchHit] {
        Self.deduplicate(try index.search(query, embedding: embedding, limit: limit), limit: limit)
    }

    public func recent(limit: Int = 20) throws -> [VaultSearchHit] {
        // `recent` is already canonical and bounded in SQL, but using the same
        // reducer keeps this contract true if aliases are included by a later
        // index schema.
        Self.deduplicate(try index.recent(limit: limit), limit: limit)
    }

    /// Deduplicates by `canonicalObjectID` without throwing away useful UI
    /// details. The best hit supplies filename/snippet/alias display identity;
    /// fields from all equivalent hits are merged in stable order.
    public static func deduplicate(_ hits: [VaultSearchHit], limit: Int? = nil) -> [VaultSearchHit] {
        var rows: [VaultObjectID: VaultSearchHit] = [:]
        var order: [VaultObjectID] = []
        for hit in hits {
            let key = hit.canonicalObjectID
            guard let existing = rows[key] else {
                rows[key] = hit; order.append(key); continue
            }
            let preferred = isPreferred(hit, over: existing) ? hit : existing
            var fields = existing.matchedFields
            for field in hit.matchedFields where !fields.contains(field) { fields.append(field) }
            // A non-empty snippet is useful even when a tie-break selects a
            // hit whose source had no extractable text.
            let snippet = preferred.snippet.isEmpty ? (existing.snippet.isEmpty ? hit.snippet : existing.snippet) : preferred.snippet
            rows[key] = VaultSearchHit(objectID: preferred.objectID,
                canonicalObjectID: key, filename: preferred.filename,
                snippet: snippet, snippetSource: preferred.snippet.isEmpty ? existing.snippetSource : preferred.snippetSource,
                score: preferred.score, createdAt: preferred.createdAt,
                updatedAt: preferred.updatedAt, accessedAt: preferred.accessedAt,
                source: preferred.source, matchedFields: fields,
                isSymbolicAlias: preferred.isSymbolicAlias)
        }
        let output = order.compactMap { rows[$0] }
        guard let limit else { return output }
        return Array(output.prefix(max(0, limit)))
    }

    private static func isPreferred(_ candidate: VaultSearchHit, over current: VaultSearchHit) -> Bool {
        if candidate.score != current.score { return candidate.score > current.score }
        if candidate.isSymbolicAlias != current.isSymbolicAlias {
            // Keep alias provenance visible when relevance ties.
            return candidate.isSymbolicAlias
        }
        if candidate.matchedFields.count != current.matchedFields.count {
            return candidate.matchedFields.count > current.matchedFields.count
        }
        if candidate.accessedAt != current.accessedAt { return candidate.accessedAt > current.accessedAt }
        return candidate.objectID.rawValue.uuidString < current.objectID.rawValue.uuidString
    }
}

public typealias VaultSearchPresenter = VaultSearchPresentationFacade

