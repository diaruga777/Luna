import Foundation

/// One sheet. The text lives in a `.md` file at `fileRelativePath`; every
/// field here is the list-view metadata kept in `writer.sqlite`.
public struct WriterDocument: Codable, Equatable, Identifiable, Sendable {
    public var id: DocumentID
    public var groupID: GroupID
    /// Derived by `TitleDeriver` on every save and stored for lists.
    public var title: String
    /// The first characters after the title line.
    public var snippet: String
    public var sortIndex: Int
    public var isFavorite: Bool
    /// Lower-cased and unique.
    public var keywords: [String]
    public var goal: WritingGoal?
    /// Relative to the library root.
    public var fileRelativePath: String
    public var wordCount: Int
    public var characterCount: Int
    public var sentenceCount: Int
    /// Bumps once per saved text change.
    public var revision: Int64
    public var createdAt: Date
    public var updatedAt: Date
    public var trashedAt: Date?

    public init(
        id: DocumentID = DocumentID(),
        groupID: GroupID,
        title: String = "",
        snippet: String = "",
        sortIndex: Int = 0,
        isFavorite: Bool = false,
        keywords: [String] = [],
        goal: WritingGoal? = nil,
        fileRelativePath: String = "",
        wordCount: Int = 0,
        characterCount: Int = 0,
        sentenceCount: Int = 0,
        revision: Int64 = 0,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        trashedAt: Date? = nil
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
        self.sentenceCount = sentenceCount
        self.revision = revision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.trashedAt = trashedAt
    }
}

public struct WritingGoal: Codable, Equatable, Sendable {
    public enum Unit: String, Codable, Sendable, CaseIterable {
        case words, characters, sentences, readingMinutes
    }

    public enum Mode: String, Codable, Sendable, CaseIterable {
        case atLeast, atMost, about
    }

    public var unit: Unit
    public var target: Int
    public var mode: Mode

    public init(unit: Unit, target: Int, mode: Mode = .atLeast) {
        self.unit = unit
        self.target = target
        self.mode = mode
    }
}

public enum DocumentSort: String, Codable, Sendable, CaseIterable {
    case manual, titleAscending, modifiedDescending, createdDescending
}
