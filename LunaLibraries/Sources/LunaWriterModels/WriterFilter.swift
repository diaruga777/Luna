import Foundation

/// A saved smart filter over the library.
public struct WriterFilter: Codable, Equatable, Identifiable, Sendable {
    public var id: FilterID
    /// nil means the whole library.
    public var scopeGroupID: GroupID?
    public var name: String
    public var predicate: FilterPredicate
    public var sortIndex: Int

    public init(
        id: FilterID = FilterID(),
        scopeGroupID: GroupID? = nil,
        name: String,
        predicate: FilterPredicate = FilterPredicate(),
        sortIndex: Int = 0
    ) {
        self.id = id
        self.scopeGroupID = scopeGroupID
        self.name = name
        self.predicate = predicate
        self.sortIndex = sortIndex
    }
}

public struct FilterPredicate: Codable, Equatable, Sendable {
    /// A document matches only when it carries every keyword listed.
    public var keywordsAll: [String]
    public var searchText: String?
    public var favoritesOnly: Bool
    public var modifiedWithin: TimeInterval?

    public init(
        keywordsAll: [String] = [],
        searchText: String? = nil,
        favoritesOnly: Bool = false,
        modifiedWithin: TimeInterval? = nil
    ) {
        self.keywordsAll = keywordsAll
        self.searchText = searchText
        self.favoritesOnly = favoritesOnly
        self.modifiedWithin = modifiedWithin
    }
}
