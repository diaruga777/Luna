import Foundation
import LunaVaultEmbeddings
import LunaVaultModels

public enum LunaVaultSearchModule { public static let identifier = "LunaVaultSearch" }

public struct VaultSearchConfiguration: Equatable, Sendable {
    public let maximumResults: Int
    public let maximumLexicalCandidates: Int
    public let maximumAutomaticGroups: Int
    public init(maximumResults: Int = 50, maximumLexicalCandidates: Int = 500,
                maximumAutomaticGroups: Int = 512) {
        self.maximumResults = maximumResults
        self.maximumLexicalCandidates = maximumLexicalCandidates
        self.maximumAutomaticGroups = maximumAutomaticGroups
    }
}

/// Progress reported after a durable bulk-index batch has committed.  The
/// callback is deliberately post-commit so a caller can persist this cursor
/// and safely resume by replaying the source.  Replayed revisions are
/// idempotently skipped by the index.
public struct VaultIndexBatchProgress: Equatable, Sendable {
    public let batchNumber: Int
    public let documentsProcessed: Int
    public let documentsApplied: Int
    public let documentsSkipped: Int

    public init(batchNumber: Int, documentsProcessed: Int,
                documentsApplied: Int, documentsSkipped: Int) {
        self.batchNumber = batchNumber
        self.documentsProcessed = documentsProcessed
        self.documentsApplied = documentsApplied
        self.documentsSkipped = documentsSkipped
    }
}

/// Totals for a completed streaming index operation.  `documentsProcessed`
/// counts source elements, while `documentsApplied` counts revisions that
/// changed the index.  A failed operation does not return a result; callbacks
/// received before the failure describe the committed prefix.
public struct VaultIndexBulkResult: Equatable, Sendable {
    public let batchesCommitted: Int
    public let documentsProcessed: Int
    public let documentsApplied: Int
    public let documentsSkipped: Int

    public init(batchesCommitted: Int, documentsProcessed: Int,
                documentsApplied: Int, documentsSkipped: Int) {
        self.batchesCommitted = batchesCommitted
        self.documentsProcessed = documentsProcessed
        self.documentsApplied = documentsApplied
        self.documentsSkipped = documentsSkipped
    }
}

public enum VaultDocumentSource: String, Codable, CaseIterable, Sendable { case device, iCloud, mac }

public struct VaultIndexRevision: Codable, Hashable, Sendable, Comparable {
    public let logicalTime: Int64
    public let deviceID: String
    public let revision: UUID
    public init(logicalTime: Int64, deviceID: String, revision: UUID = UUID()) {
        self.logicalTime = logicalTime; self.deviceID = deviceID; self.revision = revision
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.logicalTime != rhs.logicalTime { return lhs.logicalTime < rhs.logicalTime }
        if lhs.deviceID != rhs.deviceID { return Self.utf8Precedes(lhs.deviceID, rhs.deviceID) }
        return Self.utf8Precedes(lhs.revision.uuidString, rhs.revision.uuidString)
    }

    /// SQLite's default BINARY collation orders TEXT by raw UTF-8 byte
    /// sequence; Swift's `String <` orders by Unicode canonical comparison
    /// instead, which can diverge for non-ASCII device IDs. The bulk upsert
    /// path's `WHERE excluded.device_id > documents.device_id` runs in
    /// SQLite, so this comparison must match it byte-for-byte or the two
    /// paths can pick different winners for the same conflicting pair.
    private static func utf8Precedes(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

public struct VaultIndexedDocument: Equatable, Sendable {
    public let id: VaultObjectID
    public let stamp: VaultIndexRevision
    public let filename: String
    public let bodyText: String
    public let ocrText: String
    public let transcriptText: String
    public let createdAt: Date
    public let updatedAt: Date
    public let accessedAt: Date
    public let source: VaultDocumentSource
    public let embedding: VaultEmbedding?
    public let isTombstone: Bool

    public var revision: UUID { stamp.revision }
    public var logicalTime: Int64 { stamp.logicalTime }
    public var deviceID: String { stamp.deviceID }

    public init(id: VaultObjectID, revision: UUID, logicalTime: Int64 = 0, deviceID: String = "",
                filename: String, bodyText: String = "", ocrText: String = "",
                transcriptText: String = "", createdAt: Date, updatedAt: Date,
                accessedAt: Date, source: VaultDocumentSource = .device,
                embedding: VaultEmbedding? = nil, isTombstone: Bool = false) {
        self.id = id; stamp = VaultIndexRevision(logicalTime: logicalTime, deviceID: deviceID, revision: revision)
        self.filename = filename; self.bodyText = bodyText; self.ocrText = ocrText
        self.transcriptText = transcriptText; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.accessedAt = accessedAt; self.source = source; self.embedding = embedding
        self.isTombstone = isTombstone
    }
}

public enum VaultSearchField: String, Codable, Sendable { case filename, text, ocr, transcript, vector, aliasLabel }

public struct VaultSearchHit: Equatable, Sendable {
    public let objectID: VaultObjectID
    public let canonicalObjectID: VaultObjectID
    public let filename: String
    public let snippet: String
    public let snippetSource: VaultSearchField
    public let score: Double
    public let createdAt: Date
    public let updatedAt: Date
    public let accessedAt: Date
    public let source: VaultDocumentSource
    public let matchedFields: [String]
    public let isSymbolicAlias: Bool
    public init(objectID: VaultObjectID, canonicalObjectID: VaultObjectID, filename: String,
                snippet: String, snippetSource: VaultSearchField, score: Double,
                createdAt: Date, updatedAt: Date, accessedAt: Date,
                source: VaultDocumentSource, matchedFields: [String] = [],
                isSymbolicAlias: Bool = false) {
        self.objectID = objectID; self.canonicalObjectID = canonicalObjectID
        self.filename = filename; self.snippet = snippet; self.snippetSource = snippetSource
        self.score = score; self.createdAt = createdAt; self.updatedAt = updatedAt
        self.accessedAt = accessedAt; self.source = source; self.matchedFields = matchedFields
        self.isSymbolicAlias = isSymbolicAlias
    }
}

public protocol VaultGroupNaming: Sendable { func name(for members: [VaultIndexedDocument]) -> String }

public struct KeywordVaultGroupNamer: VaultGroupNaming {
    public init() {}
    public func name(for members: [VaultIndexedDocument]) -> String {
        let stop: Set<String> = ["the", "and", "for", "with", "from", "this", "that", "file"]
        var counts: [String: Int] = [:]
        for member in members {
            for word in (member.filename + " " + member.bodyText).lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                where word.count > 2 && !stop.contains(word) { counts[word, default: 0] += 1 }
        }
        let words = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(3).map(\.key)
        return words.isEmpty ? "Untitled group" : words.map(\.capitalized).joined(separator: " · ")
    }
}

public struct VaultGroup: Equatable, Sendable {
    public let id: UUID; public var label: String; public var memberIDs: [VaultObjectID]
    public var frozen: Bool; public let automatic: Bool; public let createdAt: Date
    public var updatedAt: Date
    public init(id: UUID, label: String, memberIDs: [VaultObjectID], frozen: Bool = false,
                automatic: Bool = true, createdAt: Date, updatedAt: Date) {
        self.id=id; self.label=label; self.memberIDs=memberIDs; self.frozen=frozen
        self.automatic=automatic; self.createdAt=createdAt; self.updatedAt=updatedAt
    }
}

public struct VaultQueryGroup: Equatable, Sendable {
    public let id: UUID; public let query: String; public let memberIDs: [VaultObjectID]
    public let live: Bool; public let createdAt: Date
    public init(id: UUID, query: String, memberIDs: [VaultObjectID], live: Bool, createdAt: Date) {
        self.id=id; self.query=query; self.memberIDs=memberIDs; self.live=live; self.createdAt=createdAt
    }
}

public struct VaultSymbolicAlias: Equatable, Sendable {
    public let id: UUID; public let originalObjectID: VaultObjectID; public let groupID: UUID
    public let modelVersion: String; public let embedding: VaultEmbedding
    public init(id: UUID, originalObjectID: VaultObjectID, groupID: UUID, embedding: VaultEmbedding) {
        self.id=id; self.originalObjectID=originalObjectID; self.groupID=groupID
        modelVersion=embedding.modelVersion; self.embedding=embedding
    }
}

public enum VaultSearchError: Error, Equatable, Sendable {
    case sqlite(String)
    case invalidQuery
    case invalidLimit(Int)
    case mixedModelSpace
    case dimensionMismatch(expected: Int, actual: Int)
    case missingDocument
    case tombstonedDocument
    case invalidSnapshotMember
    case invalidArtifact
    case invalidBatchSize(Int)
}
