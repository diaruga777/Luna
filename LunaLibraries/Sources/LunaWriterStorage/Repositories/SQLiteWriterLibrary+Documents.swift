import Foundation
import LunaWriterModels

extension SQLiteWriterLibrary {

    static let documentColumns =
        "id, group_id, title, snippet, sort_index, favorite, goal_unit, goal_target, goal_mode,"
        + " file_path, word_count, char_count, revision, created_at, updated_at, trashed_at"

    // MARK: - Reading

    public func documents(in group: GroupID, sort: DocumentSort) throws -> [WriterDocument] {
        let isTrash = group == trashGroupID
        let sql = "SELECT \(Self.documentColumns) FROM documents WHERE "
            + (isTrash ? "trashed_at IS NOT NULL" : "group_id = ? AND trashed_at IS NULL")
            + " ORDER BY " + Self.orderClause(sort)
        return try loadDocuments(sql) { statement in
            if !isTrash { try statement.bind(1, group.rawValue.uuidString) }
        }
    }

    public func document(_ id: DocumentID) throws -> WriterDocument? {
        try loadDocuments("SELECT \(Self.documentColumns) FROM documents WHERE id = ?") { statement in
            try statement.bind(1, id.rawValue.uuidString)
        }.first
    }

    public func favorites() throws -> [WriterDocument] {
        try loadDocuments(
            "SELECT \(Self.documentColumns) FROM documents"
            + " WHERE favorite = 1 AND trashed_at IS NULL ORDER BY updated_at DESC")
    }

    public func recent(days: Int) throws -> [WriterDocument] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return try loadDocuments(
            "SELECT \(Self.documentColumns) FROM documents"
            + " WHERE trashed_at IS NULL AND updated_at >= ? ORDER BY updated_at DESC"
        ) { statement in
            try statement.bind(1, date: cutoff)
        }
    }

    public func documents(matching predicate: FilterPredicate, scope: GroupID?) throws -> [WriterDocument] {
        var sql = "SELECT \(Self.documentColumns) FROM documents d WHERE trashed_at IS NULL"
        var binds: [(WriterStatement, Int32) throws -> Void] = []

        if let scope {
            let subtree = try groupSubtree(of: scope).map { "'\($0.rawValue.uuidString)'" }
            sql += " AND group_id IN (\(subtree.joined(separator: ",")))"
        }
        if predicate.favoritesOnly { sql += " AND favorite = 1" }
        if let within = predicate.modifiedWithin {
            let cutoff = Date().addingTimeInterval(-within)
            sql += " AND updated_at >= ?"
            binds.append { statement, index in try statement.bind(index, date: cutoff) }
        }
        let keywords = Self.normalizedKeywords(predicate.keywordsAll)
        for keyword in keywords {
            sql += " AND EXISTS (SELECT 1 FROM document_keywords k"
                + " WHERE k.document_id = d.id AND k.keyword = ?)"
            binds.append { statement, index in try statement.bind(index, keyword) }
        }
        sql += " ORDER BY updated_at DESC"

        var matches = try loadDocuments(sql) { statement in
            for (offset, bind) in binds.enumerated() { try bind(statement, Int32(offset + 1)) }
        }
        if let text = predicate.searchText, !text.trimmingCharacters(in: .whitespaces).isEmpty {
            let hits = try searchDocuments(text, limit: 500)
            let allowed = Set(hits.map(\.documentID))
            matches = matches.filter { allowed.contains($0.id) }
        }
        return matches
    }

    private static func orderClause(_ sort: DocumentSort) -> String {
        switch sort {
        case .manual: return "sort_index ASC, created_at ASC"
        case .titleAscending: return "title COLLATE NOCASE ASC, created_at ASC"
        case .modifiedDescending: return "updated_at DESC"
        case .createdDescending: return "created_at DESC"
        }
    }

    func loadDocuments(
        _ sql: String, _ bind: (WriterStatement) throws -> Void = { _ in }
    ) throws -> [WriterDocument] {
        try database.perform { db in
            var documents: [WriterDocument] = []
            try db.query(sql, bind) { row in
                if let document = Self.document(from: row) { documents.append(document) }
            }
            guard !documents.isEmpty else { return [] }
            var keywords: [DocumentID: [String]] = [:]
            let ids = documents.map { "'\($0.id.rawValue.uuidString)'" }.joined(separator: ",")
            try db.query(
                "SELECT document_id, keyword FROM document_keywords WHERE document_id IN (\(ids))"
                + " ORDER BY keyword ASC"
            ) { row in
                guard let uuid = row.uuid(0), let keyword = row.string(1) else { return }
                keywords[DocumentID(uuid), default: []].append(keyword)
            }
            return documents.map { document in
                var copy = document
                copy.keywords = keywords[document.id] ?? []
                return copy
            }
        }
    }

    // MARK: - Writing

    public func createDocument(in group: GroupID, title: String?) throws -> WriterDocument {
        let now = Date()
        let resolved = title.flatMap { $0.isEmpty ? nil : $0 }
            ?? L10nWriterStorage.untitledDocumentTitle
        let nextIndex = Int((try database.perform { db in
            try db.scalarInt(
                "SELECT COALESCE(MAX(sort_index), -1) + 1 FROM documents WHERE group_id = ?"
            ) { statement in
                try statement.bind(1, group.rawValue.uuidString)
            }
        }) ?? 0)
        let document = WriterDocument(
            groupID: group, title: resolved, snippet: "", sortIndex: nextIndex,
            createdAt: now, updatedAt: now)
        try database.transaction { db in
            try db.run(
                """
                INSERT INTO documents (id, group_id, title, snippet, sort_index, favorite,
                    goal_unit, goal_target, goal_mode, file_path, word_count, char_count,
                    revision, created_at, updated_at, trashed_at)
                VALUES (?, ?, ?, '', ?, 0, NULL, NULL, NULL, '', 0, 0, 0, ?, ?, NULL)
                """
            ) { statement in
                try statement.bind(1, document.id.rawValue.uuidString)
                try statement.bind(2, group.rawValue.uuidString)
                try statement.bind(3, resolved)
                try statement.bind(4, nextIndex)
                try statement.bind(5, date: now)
                try statement.bind(6, date: now)
            }
        }
        changes.post(.documents(in: group))
        return document
    }

    /// Writes every metadata column from `document` and stamps `updated_at`
    /// with now, so a later folder scan reads the row as newer than the file
    /// this save produced.
    public func update(_ document: WriterDocument) throws {
        try database.transaction { db in
            try db.run(
                """
                UPDATE documents SET group_id = ?, title = ?, snippet = ?, sort_index = ?,
                    favorite = ?, goal_unit = ?, goal_target = ?, goal_mode = ?, file_path = ?,
                    word_count = ?, char_count = ?, revision = ?, updated_at = ?, trashed_at = ?
                WHERE id = ?
                """
            ) { statement in
                try statement.bind(1, document.groupID.rawValue.uuidString)
                try statement.bind(2, document.title)
                try statement.bind(3, document.snippet)
                try statement.bind(4, document.sortIndex)
                try statement.bind(5, document.isFavorite)
                try statement.bind(6, document.goal?.unit.rawValue)
                try statement.bind(7, int: document.goal?.target)
                try statement.bind(8, document.goal?.mode.rawValue)
                try statement.bind(9, document.fileRelativePath)
                try statement.bind(10, document.wordCount)
                try statement.bind(11, document.characterCount)
                try statement.bind(12, document.revision)
                try statement.bind(13, date: Date())
                try statement.bind(14, date: document.trashedAt)
                try statement.bind(15, document.id.rawValue.uuidString)
            }
            try db.run("DELETE FROM document_keywords WHERE document_id = ?") { statement in
                try statement.bind(1, document.id.rawValue.uuidString)
            }
            for keyword in Self.normalizedKeywords(document.keywords) {
                try db.run(
                    "INSERT OR IGNORE INTO document_keywords (document_id, keyword) VALUES (?, ?)"
                ) { statement in
                    try statement.bind(1, document.id.rawValue.uuidString)
                    try statement.bind(2, keyword)
                }
            }
        }
        changes.post(.document(document.id))
    }

    public func moveDocument(_ id: DocumentID, to group: GroupID, at index: Int) throws {
        guard let existing = try document(id) else { return }
        try database.transaction { db in
            try db.run("UPDATE documents SET group_id = ?, updated_at = ? WHERE id = ?") { statement in
                try statement.bind(1, group.rawValue.uuidString)
                try statement.bind(2, date: Date())
                try statement.bind(3, id.rawValue.uuidString)
            }
            try Self.renumberDocuments(in: group, moving: id, to: index, db)
            if existing.groupID != group {
                try Self.renumberDocuments(in: existing.groupID, moving: nil, to: 0, db)
            }
        }
        changes.post(.documents(in: group))
    }

    /// Rewrites a group's sheets as 0, 1, 2 …, putting `moved` at `index`
    /// first. Renumbering rather than nudging one row keeps the order exact
    /// however many moves it has been through.
    private static func renumberDocuments(
        in group: GroupID, moving moved: DocumentID?, to index: Int, _ db: WriterDatabase
    ) throws {
        var ids: [String] = []
        try db.query(
            "SELECT id FROM documents WHERE group_id = ? AND trashed_at IS NULL"
            + " ORDER BY sort_index ASC, created_at ASC",
            { statement in try statement.bind(1, group.rawValue.uuidString) },
            row: { row in if let id = row.string(0) { ids.append(id) } })
        if let moved {
            let key = moved.rawValue.uuidString
            ids.removeAll { $0 == key }
            ids.insert(key, at: min(max(index, 0), ids.count))
        }
        for (position, id) in ids.enumerated() {
            try db.run("UPDATE documents SET sort_index = ? WHERE id = ?") { statement in
                try statement.bind(1, position)
                try statement.bind(2, id)
            }
        }
    }

    public func trash(_ id: DocumentID) throws {
        try database.transaction { db in
            try db.run("UPDATE documents SET trashed_at = ?, updated_at = ? WHERE id = ?") { statement in
                try statement.bind(1, date: Date())
                try statement.bind(2, date: Date())
                try statement.bind(3, id.rawValue.uuidString)
            }
        }
        changes.post(.document(id))
    }

    public func restore(_ id: DocumentID) throws {
        try database.transaction { db in
            try db.run("UPDATE documents SET trashed_at = NULL, updated_at = ? WHERE id = ?") { statement in
                try statement.bind(1, date: Date())
                try statement.bind(2, id.rawValue.uuidString)
            }
        }
        changes.post(.document(id))
    }

    public func emptyTrash() throws {
        try database.transaction { db in
            try db.execute("DELETE FROM documents WHERE trashed_at IS NOT NULL")
        }
        changes.post(.documents(in: trashGroupID))
    }

    // MARK: - Search

    public func searchDocuments(_ text: String, limit: Int) throws -> [DocumentHit] {
        guard let match = FTSQuery.make(text, prefixMatchesLastToken: true) else { return [] }
        return try DocumentFTSSearch.candidates(match: match, limit: limit, in: database)
            .map { DocumentHit(documentID: $0.id, score: HybridScorer.lexical(bm25Rank: $0.bm25)) }
    }

    // MARK: - Filters

    public func filters() throws -> [WriterFilter] {
        try database.perform { db in
            var rows: [(WriterFilter, FilterID)] = []
            try db.query(
                "SELECT id, scope_group_id, name, sort_index, search_text, favorites_only,"
                + " modified_within FROM filters ORDER BY sort_index ASC, name ASC"
            ) { row in
                guard let uuid = row.uuid(0), let name = row.string(2) else { return }
                let id = FilterID(uuid)
                let predicate = FilterPredicate(
                    keywordsAll: [], searchText: row.string(4),
                    favoritesOnly: row.bool(5), modifiedWithin: row.double(6))
                rows.append((WriterFilter(
                    id: id, scopeGroupID: row.uuid(1).map(GroupID.init), name: name,
                    predicate: predicate, sortIndex: row.int(3)), id))
            }
            var keywords: [FilterID: [String]] = [:]
            try db.query("SELECT filter_id, keyword FROM filter_keywords ORDER BY keyword ASC") { row in
                guard let uuid = row.uuid(0), let keyword = row.string(1) else { return }
                keywords[FilterID(uuid), default: []].append(keyword)
            }
            return rows.map { filter, id in
                var copy = filter
                copy.predicate.keywordsAll = keywords[id] ?? []
                return copy
            }
        }
    }

    public func save(_ filter: WriterFilter) throws {
        try database.transaction { db in
            try db.run(
                """
                INSERT INTO filters (id, scope_group_id, name, sort_index, search_text,
                    favorites_only, modified_within)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET scope_group_id = excluded.scope_group_id,
                    name = excluded.name, sort_index = excluded.sort_index,
                    search_text = excluded.search_text, favorites_only = excluded.favorites_only,
                    modified_within = excluded.modified_within
                """
            ) { statement in
                try statement.bind(1, filter.id.rawValue.uuidString)
                try statement.bind(2, filter.scopeGroupID?.rawValue.uuidString)
                try statement.bind(3, filter.name)
                try statement.bind(4, filter.sortIndex)
                try statement.bind(5, filter.predicate.searchText)
                try statement.bind(6, filter.predicate.favoritesOnly)
                try statement.bind(7, filter.predicate.modifiedWithin)
            }
            try db.run("DELETE FROM filter_keywords WHERE filter_id = ?") { statement in
                try statement.bind(1, filter.id.rawValue.uuidString)
            }
            for keyword in Self.normalizedKeywords(filter.predicate.keywordsAll) {
                try db.run("INSERT INTO filter_keywords (filter_id, keyword) VALUES (?, ?)") { statement in
                    try statement.bind(1, filter.id.rawValue.uuidString)
                    try statement.bind(2, keyword)
                }
            }
        }
        changes.post(.groups)
    }

    public func deleteFilter(_ id: FilterID) throws {
        try database.transaction { db in
            try db.run("DELETE FROM filters WHERE id = ?") { statement in
                try statement.bind(1, id.rawValue.uuidString)
            }
        }
        changes.post(.groups)
    }

    // MARK: - Row mapping

    /// Ulysses keywords are lower-cased and unique; the column is the only
    /// place that is enforced, so both writers go through here.
    static func normalizedKeywords(_ keywords: [String]) -> [String] {
        var seen = Set<String>()
        return keywords
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    static func document(from row: WriterStatement) -> WriterDocument? {
        guard let id = row.uuid(0), let groupID = row.uuid(1) else { return nil }
        var goal: WritingGoal?
        if let target = row.intOrNil(7) {
            goal = WritingGoal(
                unit: WritingGoal.Unit(rawValue: row.string(6) ?? "") ?? .words,
                target: target,
                mode: WritingGoal.Mode(rawValue: row.string(8) ?? "") ?? .atLeast)
        }
        return WriterDocument(
            id: DocumentID(id), groupID: GroupID(groupID),
            title: row.string(2) ?? "", snippet: row.string(3) ?? "",
            sortIndex: row.int(4), isFavorite: row.bool(5), keywords: [], goal: goal,
            fileRelativePath: row.string(9) ?? "", wordCount: row.int(10),
            characterCount: row.int(11), revision: row.int64(12),
            createdAt: row.date(13) ?? Date(), updatedAt: row.date(14) ?? Date(),
            trashedAt: row.date(15))
    }
}
