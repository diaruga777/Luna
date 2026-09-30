import Foundation
import SQLite3

/// Immutable bundled data, read by indexed queries. A separate connection to
/// this read-only resource never participates in the shared store's lifecycle.
public final class KeyboardCatalog {
  private var db: OpaquePointer?
  private let lock = NSLock()
  public init() {
    if let url = KeyboardResources.url("KeyboardCatalog", extension: "sqlite") {
      sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
      sqlite3_exec(db, "PRAGMA cache_size=-256", nil, nil, nil)
    }
  }
  deinit { sqlite3_close_v2(db) }
  public func glyphs(for keyword: String, limit: Int = 24) -> [(text: String, name: String)] {
    let key = keyword.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
    return query(
      "SELECT DISTINCT g.text,g.name FROM keywords k JOIN glyphs g ON g.id=k.glyph_id WHERE k.keyword=? COLLATE NOCASE ORDER BY g.id LIMIT ?",
      strings: [key], limit: limit
    ).map { ($0.0, $0.1) }
  }
  public func browseGlyphs(query text: String, limit: Int = 100) -> [(text: String, name: String)] {
    if text.isEmpty {
      return query("SELECT text,name FROM glyphs ORDER BY id LIMIT ?", strings: [], limit: limit)
        .map { ($0.0, $0.1) }
    }
    return query(
      "SELECT DISTINCT g.text,g.name FROM keywords k JOIN glyphs g ON g.id=k.glyph_id WHERE k.keyword>=? COLLATE NOCASE AND k.keyword<? COLLATE NOCASE ORDER BY g.id LIMIT ?",
      strings: [text.lowercased(), text.lowercased() + "\u{10ffff}"], limit: limit
    ).map { ($0.0, $0.1) }
  }
  public func swipeWords(language: String, first: String, last: String) -> [(String, Int)] {
    query(
      "SELECT word,frequency FROM words WHERE language=? AND first=? AND last=? ORDER BY frequency DESC LIMIT ?",
      strings: [String(language.prefix(2)), first, last], limit: 600
    ).map { ($0.0, Int($0.1) ?? 1) }
  }
  private func query(_ sql: String, strings: [String], limit: Int) -> [(String, String)] {
    lock.lock()
    defer { lock.unlock() }
    guard let db else { return [] }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    for (i, string) in strings.enumerated() {
      sqlite3_bind_text(statement, Int32(i + 1), string, -1, transient)
    }
    sqlite3_bind_int(statement, Int32(strings.count + 1), Int32(limit))
    var result: [(String, String)] = []
    while sqlite3_step(statement) == SQLITE_ROW {
      guard let a = sqlite3_column_text(statement, 0), let b = sqlite3_column_text(statement, 1)
      else { continue }
      result.append((String(cString: a), String(cString: b)))
    }
    return result
  }
}
