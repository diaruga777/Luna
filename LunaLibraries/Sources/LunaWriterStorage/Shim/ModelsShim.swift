// Shim: delete when LunaWriterModels merges.
//
// `claudedocs/plans/writer-app.md` §3 defines these types in LunaWriterModels,
// which is written in parallel. They are reproduced here so this tier compiles
// on its own. `NoteAttachment` and `NotePlacement` are NOT in §3: keep them
// when this file goes, unless the merged module declares them.

import Foundation

public struct DocumentID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct GroupID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct NoteID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct AnnotationID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct FilterID: Hashable, Codable, Sendable {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

public struct WriterGroup: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case user, inbox, trash }
    public var id: GroupID
    public var parentID: GroupID?
    public var name: String
    public var iconName: String
    public var sortIndex: Int
    public var kind: Kind
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: GroupID = GroupID(), parentID: GroupID? = nil, name: String,
        iconName: String = "folder", sortIndex: Int = 0, kind: Kind = .user,
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.iconName = iconName
        self.sortIndex = sortIndex
        self.kind = kind
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct WritingGoal: Codable, Equatable, Sendable {
    public enum Unit: String, Codable, Sendable { case words, characters, sentences, readingMinutes }
    public enum Mode: String, Codable, Sendable { case atLeast, atMost, about }
    public var unit: Unit
    public var target: Int
    public var mode: Mode

    public init(unit: Unit, target: Int, mode: Mode) {
        self.unit = unit
        self.target = target
        self.mode = mode
    }
}

public struct WriterDocument: Codable, Equatable, Identifiable, Sendable {
    public var id: DocumentID
    public var groupID: GroupID
    public var title: String
    public var snippet: String
    public var sortIndex: Int
    public var isFavorite: Bool
    public var keywords: [String]
    public var goal: WritingGoal?
    public var fileRelativePath: String
    public var wordCount: Int
    public var characterCount: Int
    public var revision: Int64
    public var createdAt: Date
    public var updatedAt: Date
    public var trashedAt: Date?

    public init(
        id: DocumentID = DocumentID(), groupID: GroupID, title: String, snippet: String = "",
        sortIndex: Int = 0, isFavorite: Bool = false, keywords: [String] = [],
        goal: WritingGoal? = nil, fileRelativePath: String = "", wordCount: Int = 0,
        characterCount: Int = 0, revision: Int64 = 0, createdAt: Date = Date(),
        updatedAt: Date = Date(), trashedAt: Date? = nil
    ) {
        self.id = id
        self.groupID = groupID
        self.title = title
        self.snippet = snippet
        self.sortIndex = sortIndex
        self.isFavorite = isFavorite
        self.keywords = keywords
        self.goal = goal
        self.fileRelativePath = fileRelativePath
        self.wordCount = wordCount
        self.characterCount = characterCount
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.trashedAt = trashedAt
    }
}

public struct TextAnchor: Codable, Equatable, Sendable {
    public var start: Int
    public var end: Int
    public var exact: String
    public var prefix: String
    public var suffix: String

    public init(start: Int, end: Int, exact: String, prefix: String = "", suffix: String = "") {
        self.start = start
        self.end = end
        self.exact = exact
        self.prefix = prefix
        self.suffix = suffix
    }
}

public struct WriterNote: Codable, Equatable, Identifiable, Sendable {
    public enum Source: String, Codable, Sendable { case typed, mention, intent, voice }
    public var id: NoteID
    public var documentIDs: [DocumentID]
    public var text: String
    public var source: Source
    public var anchor: TextAnchor?
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: NoteID = NoteID(), documentIDs: [DocumentID] = [], text: String,
        source: Source = .typed, anchor: TextAnchor? = nil,
        createdAt: Date = Date(), updatedAt: Date = Date()
    ) {
        self.id = id
        self.documentIDs = documentIDs
        self.text = text
        self.source = source
        self.anchor = anchor
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct Annotation: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case needsWork, expand, cut, keep, comment }
    public enum Source: String, Codable, Sendable { case voice, manual }
    public var id: AnnotationID
    public var documentID: DocumentID
    public var kind: Kind
    public var source: Source
    public var noteID: NoteID?
    public var anchor: TextAnchor
    public var createdAt: Date

    public init(
        id: AnnotationID = AnnotationID(), documentID: DocumentID, kind: Kind,
        source: Source = .manual, noteID: NoteID? = nil, anchor: TextAnchor,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.documentID = documentID
        self.kind = kind
        self.source = source
        self.noteID = noteID
        self.anchor = anchor
        self.createdAt = createdAt
    }
}

public struct TextRange: Codable, Equatable, Sendable {
    public var start: Int
    public var end: Int
    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }
}

public struct AuthorshipSpan: Codable, Equatable, Sendable {
    public enum Source: Codable, Equatable, Sendable {
        case author
        case pasted
        case ai(model: String)
    }
    public var range: TextRange
    public var source: Source
    public var createdAt: Date

    public init(range: TextRange, source: Source, createdAt: Date = Date()) {
        self.range = range
        self.source = source
        self.createdAt = createdAt
    }
}

public struct FilterPredicate: Codable, Equatable, Sendable {
    public var keywordsAll: [String]
    public var searchText: String?
    public var favoritesOnly: Bool
    public var modifiedWithin: TimeInterval?

    public init(
        keywordsAll: [String] = [], searchText: String? = nil,
        favoritesOnly: Bool = false, modifiedWithin: TimeInterval? = nil
    ) {
        self.keywordsAll = keywordsAll
        self.searchText = searchText
        self.favoritesOnly = favoritesOnly
        self.modifiedWithin = modifiedWithin
    }
}

public struct WriterFilter: Codable, Equatable, Identifiable, Sendable {
    public var id: FilterID
    public var scopeGroupID: GroupID?
    public var name: String
    public var predicate: FilterPredicate
    public var sortIndex: Int

    public init(
        id: FilterID = FilterID(), scopeGroupID: GroupID? = nil, name: String,
        predicate: FilterPredicate, sortIndex: Int = 0
    ) {
        self.id = id
        self.scopeGroupID = scopeGroupID
        self.name = name
        self.predicate = predicate
        self.sortIndex = sortIndex
    }
}

public enum DocumentSort: String, Codable, CaseIterable, Sendable {
    case manual, titleAscending, modifiedDescending, createdDescending
}

public struct NoteHit: Equatable, Sendable {
    public let noteID: NoteID
    public let score: Double
    public let snippet: String
    public init(noteID: NoteID, score: Double, snippet: String) {
        self.noteID = noteID
        self.score = score
        self.snippet = snippet
    }
}

public struct DocumentHit: Equatable, Sendable {
    public let documentID: DocumentID
    public let score: Double
    public init(documentID: DocumentID, score: Double) {
        self.documentID = documentID
        self.score = score
    }
}

/// Why a note sits on a document. Not in plan §3 — keep this declaration when
/// the shim goes, unless LunaWriterModels declares it.
public enum NoteAttachment: String, Codable, Sendable {
    case routed, created, manual, mention, voice
}

/// One document a routed note landed on. Not in plan §3 — keep this
/// declaration when the shim goes, unless LunaWriterModels declares it.
public struct NotePlacement: Equatable, Sendable {
    public let documentID: DocumentID
    public let title: String
    public let created: Bool

    public init(documentID: DocumentID, title: String, created: Bool) {
        self.documentID = documentID
        self.title = title
        self.created = created
    }
}
