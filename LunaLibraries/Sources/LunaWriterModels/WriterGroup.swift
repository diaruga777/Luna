import Foundation

/// A library folder. Groups nest through `parentID`; the library holds one
/// `inbox` row and one `trash` row that the user cannot delete.
public struct WriterGroup: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case user, inbox, trash
    }

    public var id: GroupID
    public var parentID: GroupID?
    public var name: String
    /// SF Symbol name.
    public var iconName: String
    public var sortIndex: Int
    public var kind: Kind
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: GroupID = GroupID(),
        parentID: GroupID? = nil,
        name: String,
        iconName: String = "folder",
        sortIndex: Int = 0,
        kind: Kind = .user,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
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
