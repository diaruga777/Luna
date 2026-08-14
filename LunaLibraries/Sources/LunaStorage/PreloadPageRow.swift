//
//  PreloadPageRow.swift
//  LunaStorage
//

import Foundation

/// Reads and writes the `preload_pages` row and its `preload_page_links` children.
///
/// The page's file is `files.relative_path`, joined in rather than stored twice: a
/// page's identity is its URL hash and its file is whatever the ownership tables
/// currently say it is.
enum PreloadPageRow {

    static let selectSQL = """
        SELECT preload_pages.url_key, preload_pages.url_string, preload_pages.kind,
               preload_pages.last_loaded_at, preload_pages.has_content,
               files.relative_path
        FROM preload_pages
        JOIN files ON files.id = preload_pages.file_id
        """

    /// Everything the crawl knows about a page, keyed by its URL hash.
    static func entries(in db: SavesDatabase) throws -> [String: PreloadEntry] {
        var entries: [String: PreloadEntry] = [:]
        try db.query(selectSQL) { row in
            guard let key = row.string(0), let entry = entry(from: row) else { return }
            entries[key] = entry
        }
        guard !entries.isEmpty else { return entries }
        var children: [String: [(Int, String)]] = [:]
        try db.query(
            "SELECT url_key, position, child_url_key FROM preload_page_links"
        ) { row in
            guard let key = row.string(0), let child = row.string(2) else { return }
            children[key, default: []].append((row.int(1) ?? 0, child))
        }
        for (key, links) in children {
            entries[key]?.children = links.sorted { $0.0 < $1.0 }.map(\.1)
        }
        return entries
    }

    static func entry(forKey key: String, in db: SavesDatabase) throws -> PreloadEntry? {
        var found: PreloadEntry?
        try db.query(
            "\(selectSQL) WHERE preload_pages.url_key = ?", { try $0.bind(1, key) }
        ) { row in
            if found == nil { found = entry(from: row) }
        }
        guard var entry = found else { return nil }
        var links: [(Int, String)] = []
        try db.query(
            "SELECT position, child_url_key FROM preload_page_links WHERE url_key = ?",
            { try $0.bind(1, key) }
        ) { row in
            if let child = row.string(1) { links.append((row.int(0) ?? 0, child)) }
        }
        entry.children = links.sorted { $0.0 < $1.0 }.map(\.1)
        return entry
    }

    /// Records what the crawl learned about a page that already has its row. The
    /// row itself is created by `registerPreloadPage`, alongside the file it owns.
    static func update(
        key: String, entry: PreloadEntry, in db: SavesDatabase
    ) throws {
        try db.run(
            """
            UPDATE preload_pages
            SET url_string = ?, kind = ?, last_loaded_at = ?, has_content = ?
            WHERE url_key = ?
            """
        ) {
            try $0.bind(1, entry.urlString)
            try $0.bind(2, entry.kind.rawValue)
            try $0.bind(3, date: entry.lastLoadedAt)
            try $0.bind(4, entry.contentFile != nil)
            try $0.bind(5, key)
        }
        try db.run("DELETE FROM preload_page_links WHERE url_key = ?") { try $0.bind(1, key) }
        for (position, child) in entry.children.enumerated() {
            try db.run(
                """
                INSERT OR IGNORE INTO preload_page_links (url_key, position, child_url_key)
                    SELECT ?, ?, ? WHERE EXISTS (
                        SELECT 1 FROM preload_pages WHERE url_key = ?
                    )
                """
            ) {
                try $0.bind(1, key)
                try $0.bind(2, position)
                try $0.bind(3, child)
                try $0.bind(4, key)
            }
        }
    }

    private static func entry(from row: SavesStatement) -> PreloadEntry? {
        guard let urlString = row.string(1), let path = row.string(5) else { return nil }
        let hasContent = (row.int(4) ?? 0) != 0
        return PreloadEntry(
            urlString: urlString,
            kind: row.string(2).flatMap(PreloadKind.init(rawValue:)) ?? .unrepresentable,
            contentFile: hasContent
                ? String(path.split(separator: "/").last ?? "")
                : nil,
            lastLoadedAt: row.date(3),
            children: [])
    }
}
