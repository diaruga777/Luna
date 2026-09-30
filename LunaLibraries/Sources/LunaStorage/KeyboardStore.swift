import Foundation
import LunaAppConfig

public struct KeyboardShortcut: Identifiable, Equatable {
  public let id: String
  public var keywords: [String]
  public var text: String
  public var kind: String
  public var suggestWhileTyping: Bool
  public var isCosmetic: Bool
  public var relativePath: String?
  public init(
    id: String = UUID().uuidString, keywords: [String], text: String, kind: String = "text",
    relativePath: String? = nil, suggestWhileTyping: Bool = true, isCosmetic: Bool = false
  ) {
    self.id = id
    self.keywords = keywords
    self.text = text
    self.kind = kind
    self.relativePath = relativePath
    self.suggestWhileTyping = suggestWhileTyping
    self.isCosmetic = isCosmetic
  }
}

public struct KeyboardSavedLink: Equatable {
  public let id: String
  public let title: String
  public let url: String
  public let isVideo: Bool
  public let date: Date
}

/// A bounded projection over Luna's existing connection. No Core Data, copied
/// media, decoded thumbnails, or materialized saves cache in the keyboard.
public final class KeyboardStore {
  private let saves: SavesStore
  private let container: URL?
  public init(saves: SavesStore = .shared, containerURL: URL? = nil) {
    self.saves = saves
    self.container = containerURL ?? AppConfig.sharedContainerURL()
  }

  static let schema = """
    CREATE TABLE IF NOT EXISTS keyboard_preferences (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS keyboard_shortcuts (
        id TEXT PRIMARY KEY, text TEXT NOT NULL, kind TEXT NOT NULL,
        relative_path TEXT, updated_at REAL NOT NULL
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS keyboard_shortcut_options (
        shortcut_id TEXT PRIMARY KEY REFERENCES keyboard_shortcuts(id) ON DELETE CASCADE,
        suggest_while_typing INTEGER NOT NULL DEFAULT 1, is_cosmetic INTEGER NOT NULL DEFAULT 0
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS keyboard_search_cache (
        query TEXT PRIMARY KEY, payload TEXT NOT NULL, updated_at REAL NOT NULL
    ) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS keyboard_keywords (
        shortcut_id TEXT NOT NULL REFERENCES keyboard_shortcuts(id) ON DELETE CASCADE,
        keyword TEXT NOT NULL COLLATE NOCASE, PRIMARY KEY(shortcut_id, keyword)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS keyboard_keyword_lookup ON keyboard_keywords(keyword);
    CREATE TABLE IF NOT EXISTS keyboard_dictionary (
        word TEXT NOT NULL COLLATE NOCASE, language TEXT NOT NULL,
        PRIMARY KEY(word, language)
    ) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS keyboard_recent_saves ON saves(date_added DESC) WHERE archived_at IS NULL;
    CREATE TRIGGER IF NOT EXISTS keyboard_shortcut_release AFTER DELETE ON keyboard_shortcuts BEGIN
        DELETE FROM file_holders WHERE holder_key = 'keyboard-shortcut:' || OLD.id;
    END;
    """

  public func preferences() throws -> [String: String] {
    try saves.keyboardRead { db in
      var values: [String: String] = [:]
      try db.query("SELECT key, value FROM keyboard_preferences") { row in
        if let key = row.string(0), let value = row.string(1) { values[key] = value }
      }
      return values
    }
  }
  public func setPreference(_ key: String, value: String) throws {
    try saves.keyboardWrite { db in
      try db.run(
        "INSERT INTO keyboard_preferences(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value"
      ) {
        try $0.bind(1, key)
        try $0.bind(2, value)
      }
    }
  }
  public func shortcuts(matching query: String = "", limit: Int = 100, forTyping: Bool = false) throws -> [KeyboardShortcut]
  {
    try saves.keyboardRead { db in
      var result: [KeyboardShortcut] = []
      try db.query(
        """
        SELECT s.id,s.text,s.kind,s.relative_path,COALESCE(o.suggest_while_typing,1),COALESCE(o.is_cosmetic,0)
        FROM keyboard_shortcuts s LEFT JOIN keyboard_shortcut_options o ON o.shortcut_id=s.id
        WHERE (? = '' OR EXISTS (SELECT 1 FROM keyboard_keywords k WHERE k.shortcut_id=s.id AND k.keyword=? COLLATE NOCASE))
        AND (? = 0 OR COALESCE(o.suggest_while_typing,1) = 1)
        ORDER BY s.updated_at DESC, s.id LIMIT ?
        """,
        {
          try $0.bind(1, query)
          try $0.bind(2, query)
          try $0.bind(3, forTyping ? 1 : 0)
          try $0.bind(4, max(1, min(limit, 500)))
        }
      ) { row in
        guard let id = row.string(0), let text = row.string(1), let kind = row.string(2) else {
          return
        }
        var keys: [String] = []
        try db.query(
          "SELECT keyword FROM keyboard_keywords WHERE shortcut_id=? ORDER BY keyword",
          { try $0.bind(1, id) }
        ) {
          if let key = $0.string(0) { keys.append(key) }
        }
        result.append(
          .init(id: id, keywords: keys, text: text, kind: kind, relativePath: row.string(3),
                suggestWhileTyping: row.int64(4) == 1, isCosmetic: row.int64(5) == 1))
      }
      return result
    }
  }
  public func save(_ shortcut: KeyboardShortcut, importing source: URL? = nil) throws {
    guard let container else { throw CocoaError(.fileWriteNoPermission) }
    var relative: String? = shortcut.relativePath
    var copied: URL?
    if let source {
      let directory = container.appendingPathComponent("KeyboardMedia", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let ext = source.pathExtension.lowercased()
      guard ["png", "jpg", "jpeg", "gif", "heic", "webp", "mp4", "mov"].contains(ext) else {
        throw CocoaError(.fileReadUnsupportedScheme)
      }
      let name = UUID().uuidString + "." + ext
      let dest = directory.appendingPathComponent(name)
      copied = dest
      relative = "KeyboardMedia/" + name
    }
    do {
      try saves.keyboardWrite { db in
        if let source, let copied { try FileManager.default.copyItem(at: source, to: copied) }
        // Only existing holdings or this call's fresh import may be used.
        if let relative {
          let existing = try SavedFileOwnership.holderPaths(
            holderKey: "keyboard-shortcut:" + shortcut.id, in: db)
          guard copied != nil || existing.contains(OwnedFilePath(relative)) else {
            throw CocoaError(.fileWriteInvalidFileName)
          }
        }
        let old = try SavedFileOwnership.holderPaths(
          holderKey: "keyboard-shortcut:" + shortcut.id, in: db)
        if old.map(\.relativePath) != (relative.map({ [$0] }) ?? []) {
          try SavedFileOwnership.releaseHolder(
            holderKey: "keyboard-shortcut:" + shortcut.id, in: db)
          if let relative {
            try SavedFileOwnership.attachHolder(
              path: OwnedFilePath(relative), kind: .mediaFile,
              holderKey: "keyboard-shortcut:" + shortcut.id, in: db)
          }
        }
        try db.run(
          """
          INSERT INTO keyboard_shortcuts(id,text,kind,relative_path,updated_at) VALUES(?,?,?,?,?)
          ON CONFLICT(id) DO UPDATE SET text=excluded.text,kind=excluded.kind,relative_path=excluded.relative_path,updated_at=excluded.updated_at
          """
        ) {
          try $0.bind(1, shortcut.id)
          try $0.bind(2, shortcut.text)
          try $0.bind(3, shortcut.kind)
          try $0.bind(4, relative)
          try $0.bind(5, date: Date())
        }
        try db.run("INSERT INTO keyboard_shortcut_options(shortcut_id,suggest_while_typing,is_cosmetic) VALUES(?,?,?) ON CONFLICT(shortcut_id) DO UPDATE SET suggest_while_typing=excluded.suggest_while_typing,is_cosmetic=excluded.is_cosmetic") {
          try $0.bind(1, shortcut.id)
          try $0.bind(2, shortcut.suggestWhileTyping ? 1 : 0)
          try $0.bind(3, shortcut.isCosmetic ? 1 : 0)
        }
        try db.run("DELETE FROM keyboard_keywords WHERE shortcut_id=?") {
          try $0.bind(1, shortcut.id)
        }
        for key in Set(
          shortcut.keywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        ).filter({ !$0.isEmpty }) {
          try db.run("INSERT INTO keyboard_keywords(shortcut_id,keyword) VALUES(?,?)") {
            try $0.bind(1, shortcut.id)
            try $0.bind(2, key)
          }
        }
      }
    } catch {
      if let copied { try? FileManager.default.removeItem(at: copied) }
      throw error
    }
    saves.reapPendingDeletes()
  }
  public func delete(id: String) throws {
    try saves.keyboardWrite { db in
      try db.run("DELETE FROM keyboard_shortcuts WHERE id=?") { try $0.bind(1, id) }
    }
    saves.reapPendingDeletes()
  }
  /// Imported files are created under the same write lock as their holder.
  /// A process killed before SQL commit may leave an unowned UUID file; this
  /// sweep cannot race a live import because both hold that write lock.
  public func reapAbandonedMedia() throws {
    guard let container else { return }
    let directory = container.appendingPathComponent("KeyboardMedia", isDirectory: true)
    try saves.keyboardWrite { db in
      let files =
        (try? FileManager.default.contentsOfDirectory(
          at: directory, includingPropertiesForKeys: nil)) ?? []
      for file in files
      where UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil {
        let relative = "KeyboardMedia/" + file.lastPathComponent
        let count =
          try db.scalarInt(
            "SELECT count(*) FROM files WHERE relative_path=?", { try $0.bind(1, relative) }) ?? 0
        if count == 0 { try? FileManager.default.removeItem(at: file) }
      }
    }
    saves.reapPendingDeletes()
  }

  public func mediaIsMissing(_ shortcut: KeyboardShortcut) -> Bool {
    guard shortcut.kind != "text", shortcut.relativePath != nil else { return false }
    guard let url = fileURL(for: shortcut) else { return true }
    return !FileManager.default.fileExists(atPath: url.path)
  }
  /// Explicit cleanup leaves missing entries available for repair until requested.
  public func removeMissingMedia() throws -> Int {
    var removed = 0
    for shortcut in try shortcuts(limit: 500) where mediaIsMissing(shortcut) {
      try delete(id: shortcut.id)
      removed += 1
    }
    return removed
  }
  public func cachedMediaSearch(_ query: String, maxAge: TimeInterval = 86400) throws -> String? {
    try saves.keyboardRead { db in
      var result: String?
      try db.query("SELECT payload FROM keyboard_search_cache WHERE query=? AND updated_at>?", {
        try $0.bind(1, query)
        try $0.bind(2, date: Date().addingTimeInterval(-maxAge))
      }) { result = $0.string(0) }
      return result
    }
  }
  public func cacheMediaSearch(_ query: String, payload: String) throws {
    guard payload.utf8.count <= 128 * 1024 else { return }
    try saves.keyboardWrite { db in
      try db.run("INSERT INTO keyboard_search_cache(query,payload,updated_at) VALUES(?,?,?) ON CONFLICT(query) DO UPDATE SET payload=excluded.payload,updated_at=excluded.updated_at") {
        try $0.bind(1, query); try $0.bind(2, payload); try $0.bind(3, date: Date())
      }
      try db.run("DELETE FROM keyboard_search_cache WHERE query NOT IN (SELECT query FROM keyboard_search_cache ORDER BY updated_at DESC LIMIT 20)")
    }
  }
  public func fileURL(for shortcut: KeyboardShortcut) -> URL? {
    guard let path = shortcut.relativePath, path.hasPrefix("KeyboardMedia/"), !path.contains(".."),
      let container
    else { return nil }
    return container.appendingPathComponent(path)
  }
  public func dictionary(language: String, prefix: String = "", limit: Int = 100) throws -> [String]
  {
    try saves.keyboardRead { db in
      var words: [String] = []
      try db.query(
        "SELECT word FROM keyboard_dictionary WHERE language=? AND substr(word,1,length(?))=? COLLATE NOCASE ORDER BY word LIMIT ?",
        {
          try $0.bind(1, language)
          try $0.bind(2, prefix)
          try $0.bind(3, prefix)
          try $0.bind(4, max(1, min(limit, 500)))
        }
      ) { if let word = $0.string(0) { words.append(word) } }
      return words
    }
  }
  public func setWord(_ word: String, language: String, included: Bool) throws {
    let value = word.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return }
    try saves.keyboardWrite { db in
      try db.run(
        included
          ? "INSERT OR IGNORE INTO keyboard_dictionary(word,language) VALUES(?,?)"
          : "DELETE FROM keyboard_dictionary WHERE word=? AND language=?"
      ) {
        try $0.bind(1, value)
        try $0.bind(2, language)
      }
    }
  }
  public func recentLinks(limit: Int = 12) throws -> [KeyboardSavedLink] {
    try saves.keyboardRead { db in
      var result: [KeyboardSavedLink] = []
      try db.query(
        """
        SELECT s.id, COALESCE(m.title,s.title,s.url_string),s.url_string,
               CASE WHEN m.kind='video' THEN 1 ELSE 0 END, s.date_added
        FROM saves s LEFT JOIN media_saves m ON m.save_id=s.id
        WHERE s.archived_at IS NULL AND (m.save_id IS NULL OR m.archived_at IS NULL)
            AND (s.url_string LIKE 'https://%' OR s.url_string LIKE 'http://%')
        ORDER BY s.date_added DESC,s.id LIMIT ?
        """, { try $0.bind(1, max(1, min(limit, 30))) }
      ) { row in
        guard let id = row.string(0), let title = row.string(1), let url = row.string(2) else {
          return
        }
        result.append(
          .init(
            id: id, title: title, url: url, isVideo: row.int64(3) == 1,
            date: Date(timeIntervalSinceReferenceDate: row.double(4) ?? 0)))
      }
      return result
    }
  }
}
