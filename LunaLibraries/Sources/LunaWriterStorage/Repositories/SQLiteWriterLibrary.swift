import Foundation
import LunaWriterModels

/// The library over `writer.sqlite`: groups, sheets, filters, notes, marks and
/// snapshots.
///
/// Inbox and Trash are two rows with fixed ids, created on first open. Fixed
/// ids because `inboxGroupID` / `trashGroupID` answer without throwing, and
/// because a library rebuilt from files must land on the same two groups.
///
/// A trashed sheet keeps its group and gains a `trashed_at`. The Trash listing
/// is that column, not a move, so Restore puts the sheet back where it was
/// without a column remembering where that is.
public final class SQLiteWriterLibrary: WriterLibraryStoring, NoteStoring,
                                        DocumentMarksStoring, DocumentSnapshotStoring {

    public let database: WriterDatabase
    public let inboxGroupID = GroupID(UUID(uuidString: "11B00000-0000-4000-8000-000000000001")!)
    public let trashGroupID = GroupID(UUID(uuidString: "77A50000-0000-4000-8000-000000000002")!)

    /// Moves a sheet's file when trashing, restoring or deleting its group.
    /// Installed by the stack that also owns the text store; nil (a
    /// background process with no folder) leaves file paths untouched.
    public weak var fileRelocator: DocumentFileRelocating?
    /// Kept the search index in step with metadata writes this library makes
    /// itself (`update`, `setKeywords`, `insert`/`update` for notes), so a
    /// caller editing a title or a keyword cannot forget to re-index it.
    let documentIndex: DocumentIndexing?
    let noteIndex: NoteIndexing?
    /// Read to recover a sheet's body when a metadata-only write (a keyword
    /// edit, a favourite toggle) needs to refresh the document index: the FTS
    /// table is contentless, so a document row's index entry can only be
    /// rewritten whole, and this library does not itself hold the body text.
    /// Weak, and wired after both exist: the text store takes this library as
    /// a dependency, so the reference back would otherwise be a cycle.
    public weak var textStore: DocumentTextStoring?

    let changes = LibraryChangeBroadcaster()

    public init(
        database: WriterDatabase, documentIndex: DocumentIndexing? = nil,
        noteIndex: NoteIndexing? = nil
    ) throws {
        self.database = database
        self.documentIndex = documentIndex
        self.noteIndex = noteIndex
        try createSystemGroups()
    }

    public func addObserver(_ observer: LibraryChangeObserving) { changes.add(observer) }
    public func removeObserver(_ observer: LibraryChangeObserving) { changes.remove(observer) }

    // MARK: - Groups

    private func createSystemGroups() throws {
        try database.transaction { db in
            let now = Date()
            for (id, name, icon, kind, index) in [
                (inboxGroupID, L10nWriterStorage.inboxGroupName, "tray", "inbox", 0),
                (trashGroupID, L10nWriterStorage.trashGroupName, "trash", "trash", 1_000_000),
            ] {
                try db.run(
                    """
                    INSERT INTO groups (id, parent_id, name, icon, sort_index, kind, created_at, updated_at)
                    VALUES (?, NULL, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO NOTHING
                    """
                ) { statement in
                    try statement.bind(1, id.rawValue.uuidString)
                    try statement.bind(2, name)
                    try statement.bind(3, icon)
                    try statement.bind(4, index)
                    try statement.bind(5, kind)
                    try statement.bind(6, date: now)
                    try statement.bind(7, date: now)
                }
            }
        }
    }

    public func groups() throws -> [WriterGroup] {
        try database.perform { db in
            var result: [WriterGroup] = []
            try db.query(
                "SELECT id, parent_id, name, icon, sort_index, kind, created_at, updated_at"
                + " FROM groups ORDER BY sort_index ASC, name ASC"
            ) { row in
                if let group = Self.group(from: row) { result.append(group) }
            }
            return result
        }
    }

    public func createGroup(name: String, icon: String, parent: GroupID?) throws -> WriterGroup {
        let now = Date()
        let group = WriterGroup(
            parentID: parent, name: name, iconName: icon,
            sortIndex: try nextGroupSortIndex(parent: parent), kind: .user,
            createdAt: now, updatedAt: now)
        try database.transaction { db in
            try db.run(
                """
                INSERT INTO groups (id, parent_id, name, icon, sort_index, kind, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """
            ) { statement in
                try statement.bind(1, group.id.rawValue.uuidString)
                try statement.bind(2, group.parentID?.rawValue.uuidString)
                try statement.bind(3, group.name)
                try statement.bind(4, group.iconName)
                try statement.bind(5, group.sortIndex)
                try statement.bind(6, group.kind.rawValue)
                try statement.bind(7, date: group.createdAt)
                try statement.bind(8, date: group.updatedAt)
            }
        }
        changes.post(.groups)
        return group
    }

    public func update(_ group: WriterGroup) throws {
        try database.transaction { db in
            try db.run(
                "UPDATE groups SET parent_id = ?, name = ?, icon = ?, sort_index = ?, updated_at = ?"
                + " WHERE id = ?"
            ) { statement in
                try statement.bind(1, group.parentID?.rawValue.uuidString)
                try statement.bind(2, group.name)
                try statement.bind(3, group.iconName)
                try statement.bind(4, group.sortIndex)
                try statement.bind(5, date: Date())
                try statement.bind(6, group.id.rawValue.uuidString)
            }
        }
        changes.post(.groups)
    }

    public func delete(_ id: GroupID) throws {
        guard id != inboxGroupID, id != trashGroupID else { return }
        let subtree = try groupSubtree(of: id)
        var affected: [WriterDocument] = []
        for group in subtree { affected.append(contentsOf: try documents(in: group, sort: .manual)) }
        // Moved into `.Trash` before the rows change, while each document's
        // own `fileRelativePath` still names where its file actually is.
        var relocated: [DocumentID: String] = [:]
        for document in affected {
            if let newPath = fileRelocator?.relocateToTrash(document.fileRelativePath) {
                relocated[document.id] = newPath
            }
        }
        try database.transaction { db in
            // The documents move to the Inbox and gain a trashed_at, so the
            // group's ON DELETE CASCADE cannot take them with it.
            for group in subtree {
                try db.run(
                    "UPDATE documents SET group_id = ?, trashed_at = ?, updated_at = ? WHERE group_id = ?"
                ) { statement in
                    try statement.bind(1, self.inboxGroupID.rawValue.uuidString)
                    try statement.bind(2, date: Date())
                    try statement.bind(3, date: Date())
                    try statement.bind(4, group.rawValue.uuidString)
                }
            }
            for (documentID, newPath) in relocated {
                try db.run("UPDATE documents SET file_path = ? WHERE id = ?") { statement in
                    try statement.bind(1, newPath)
                    try statement.bind(2, documentID.rawValue.uuidString)
                }
            }
            try db.run("DELETE FROM groups WHERE id = ?") { statement in
                try statement.bind(1, id.rawValue.uuidString)
            }
        }
        changes.post(.groups)
    }

    public func moveGroup(_ id: GroupID, to parent: GroupID?, at index: Int) throws {
        guard id != inboxGroupID, id != trashGroupID else { return }
        guard try !groupSubtree(of: id).contains(where: { $0 == parent }) else { return }
        let previousParent = try groups().first { $0.id == id }?.parentID
        try database.transaction { db in
            try db.run("UPDATE groups SET parent_id = ?, updated_at = ? WHERE id = ?") { statement in
                try statement.bind(1, parent?.rawValue.uuidString)
                try statement.bind(2, date: Date())
                try statement.bind(3, id.rawValue.uuidString)
            }
            try Self.renumberGroups(parent: parent, moving: id, to: index, in: db)
            if previousParent != parent {
                try Self.renumberGroups(parent: previousParent, moving: nil, to: 0, in: db)
            }
        }
        changes.post(.groups)
    }

    /// `id` and every group beneath it.
    func groupSubtree(of id: GroupID) throws -> [GroupID] {
        let all = try groups()
        var result = [id]
        var frontier = [id]
        while let current = frontier.popLast() {
            let children = all.filter { $0.parentID == current }.map(\.id)
            result.append(contentsOf: children)
            frontier.append(contentsOf: children)
        }
        return result
    }

    private func nextGroupSortIndex(parent: GroupID?) throws -> Int {
        try database.perform { db in
            let sql = parent == nil
                ? "SELECT COALESCE(MAX(sort_index), -1) + 1 FROM groups WHERE parent_id IS NULL AND kind = 'user'"
                : "SELECT COALESCE(MAX(sort_index), -1) + 1 FROM groups WHERE parent_id = ?"
            return Int((try db.scalarInt(sql) { statement in
                if let parent { try statement.bind(1, parent.rawValue.uuidString) }
            }) ?? 0)
        }
    }

    /// Rewrites a parent's children as 0, 1, 2 …, putting `moved` at `index`
    /// first. Renumbering rather than nudging one row keeps the order exact
    /// however many moves it has been through.
    private static func renumberGroups(
        parent: GroupID?, moving moved: GroupID?, to index: Int, in db: WriterDatabase
    ) throws {
        var ids: [String] = []
        let sql = parent == nil
            ? "SELECT id FROM groups WHERE parent_id IS NULL AND kind = 'user' ORDER BY sort_index ASC, name ASC"
            : "SELECT id FROM groups WHERE parent_id = ? ORDER BY sort_index ASC, name ASC"
        try db.query(sql, { statement in
            if let parent { try statement.bind(1, parent.rawValue.uuidString) }
        }, row: { row in
            if let id = row.string(0) { ids.append(id) }
        })
        if let moved {
            let key = moved.rawValue.uuidString
            ids.removeAll { $0 == key }
            ids.insert(key, at: min(max(index, 0), ids.count))
        }
        for (position, id) in ids.enumerated() {
            try db.run("UPDATE groups SET sort_index = ? WHERE id = ?") { statement in
                try statement.bind(1, position)
                try statement.bind(2, id)
            }
        }
    }

    // MARK: - Fan-in

    /// Runs a `... WHERE <col> IN (SELECT value FROM json_each(?))` query
    /// binding `ids` as one JSON array, and folds each row into a per-id
    /// list. The one place `loadDocuments` (keywords) and `loadNotes`
    /// (attachments) turn a flat row set into a dictionary keyed by the id
    /// each row belongs to.
    static func fanIn<ID: Hashable, Value>(
        _ sql: String, ids: [String], in db: WriterDatabase,
        row: (WriterStatement) -> (ID, Value)?
    ) throws -> [ID: [Value]] {
        guard !ids.isEmpty else { return [:] }
        var result: [ID: [Value]] = [:]
        try db.query(sql, { statement in try statement.bind(1, jsonArray: ids) }) { statementRow in
            guard let (id, value) = row(statementRow) else { return }
            result[id, default: []].append(value)
        }
        return result
    }

    private static func group(from row: WriterStatement) -> WriterGroup? {
        guard let uuid = row.uuid(0), let name = row.string(2) else { return nil }
        return WriterGroup(
            id: GroupID(uuid),
            parentID: row.uuid(1).map(GroupID.init),
            name: name,
            iconName: row.string(3) ?? "folder",
            sortIndex: row.int(4),
            // No CHECK on the column: a value this build does not know is a
            // user group, which is the harmless reading.
            kind: WriterGroup.Kind(rawValue: row.string(5) ?? "") ?? .user,
            createdAt: row.date(6) ?? Date(),
            updatedAt: row.date(7) ?? Date())
    }
}
