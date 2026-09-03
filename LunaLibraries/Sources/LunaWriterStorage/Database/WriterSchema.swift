import Foundation
import LunaWriterModels

/// The `writer.sqlite` schema, and the runner that brings a file up to
/// `WriterDatabase.schemaVersion`.
///
/// Every step is written so a re-run changes nothing (`IF NOT EXISTS`
/// throughout), because a file whose `user_version` was lost still holds its
/// rows and must keep them.
///
/// Enum columns carry NO CHECK constraint. Luna's rule: a raw value Swift does
/// not recognise maps to a safe default rather than failing a write.
enum WriterSchema {

    /// Applied in order, each with the `user_version` it leaves behind.
    static let migrations: [(version: Int32, sql: String)] = [(1, version1)]

    static func migrate(_ database: WriterDatabase) throws {
        let current = try database.readUserVersion()
        for step in migrations where step.version > current {
            try database.execute("BEGIN IMMEDIATE")
            do {
                try database.execute(step.sql)
                try database.setUserVersion(step.version)
                try database.execute("COMMIT")
            } catch {
                try? database.execute("ROLLBACK")
                throw error
            }
        }
        // A file whose version pragma is missing but whose tables exist is
        // brought back in line without touching its rows.
        if current > 0, current < WriterDatabase.schemaVersion {
            try database.setUserVersion(WriterDatabase.schemaVersion)
        }
    }

    /// `documents_fts` is contentless: a sheet's body lives in a `.md` file on
    /// disk, so the index has nothing to mirror. `contentless_delete=1` is what
    /// lets a re-index and the cascade trigger below remove the old row.
    private static let version1 = """
    CREATE TABLE IF NOT EXISTS groups (
        id TEXT PRIMARY KEY,
        parent_id TEXT REFERENCES groups(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        icon TEXT NOT NULL DEFAULT 'folder',
        sort_index INTEGER NOT NULL DEFAULT 0,
        kind TEXT NOT NULL DEFAULT 'user',
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS groups_parent ON groups(parent_id, sort_index);

    CREATE TABLE IF NOT EXISTS documents (
        id TEXT PRIMARY KEY,
        group_id TEXT NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
        title TEXT NOT NULL DEFAULT '',
        snippet TEXT NOT NULL DEFAULT '',
        sort_index INTEGER NOT NULL DEFAULT 0,
        favorite INTEGER NOT NULL DEFAULT 0,
        goal_unit TEXT,
        goal_target INTEGER,
        goal_mode TEXT,
        file_path TEXT NOT NULL DEFAULT '',
        word_count INTEGER NOT NULL DEFAULT 0,
        char_count INTEGER NOT NULL DEFAULT 0,
        revision INTEGER NOT NULL DEFAULT 0,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL,
        trashed_at REAL
    );
    CREATE INDEX IF NOT EXISTS documents_group ON documents(group_id, sort_index);
    CREATE INDEX IF NOT EXISTS documents_updated ON documents(updated_at);

    CREATE TABLE IF NOT EXISTS document_keywords (
        document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        keyword TEXT NOT NULL,
        PRIMARY KEY (document_id, keyword)
    );
    CREATE INDEX IF NOT EXISTS document_keywords_keyword ON document_keywords(keyword);

    CREATE VIRTUAL TABLE IF NOT EXISTS documents_fts USING fts5(
        title, body, content='', contentless_delete=1,
        tokenize='unicode61 remove_diacritics 2');

    CREATE TRIGGER IF NOT EXISTS documents_fts_ad AFTER DELETE ON documents BEGIN
        DELETE FROM documents_fts WHERE rowid = old.rowid;
    END;

    CREATE TABLE IF NOT EXISTS notes (
        id TEXT PRIMARY KEY,
        text TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL DEFAULT 'typed',
        anchor_document_id TEXT REFERENCES documents(id) ON DELETE SET NULL,
        anchor_start INTEGER,
        anchor_end INTEGER,
        anchor_exact TEXT,
        anchor_prefix TEXT,
        anchor_suffix TEXT,
        created_at REAL NOT NULL,
        updated_at REAL NOT NULL
    );

    CREATE TABLE IF NOT EXISTS note_documents (
        note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
        document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        attachment TEXT NOT NULL DEFAULT 'manual',
        PRIMARY KEY (note_id, document_id)
    );
    CREATE INDEX IF NOT EXISTS note_documents_document ON note_documents(document_id);

    CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
        text, content='notes', content_rowid='rowid',
        tokenize='unicode61 remove_diacritics 2');

    CREATE TRIGGER IF NOT EXISTS notes_fts_ai AFTER INSERT ON notes BEGIN
        INSERT INTO notes_fts(rowid, text) VALUES (new.rowid, new.text);
    END;
    CREATE TRIGGER IF NOT EXISTS notes_fts_ad AFTER DELETE ON notes BEGIN
        INSERT INTO notes_fts(notes_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
    END;
    CREATE TRIGGER IF NOT EXISTS notes_fts_au AFTER UPDATE ON notes BEGIN
        INSERT INTO notes_fts(notes_fts, rowid, text) VALUES ('delete', old.rowid, old.text);
        INSERT INTO notes_fts(rowid, text) VALUES (new.rowid, new.text);
    END;

    CREATE TABLE IF NOT EXISTS note_embeddings (
        note_id TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
        model_version TEXT NOT NULL,
        dims INTEGER NOT NULL,
        vector BLOB NOT NULL
    );

    CREATE TABLE IF NOT EXISTS document_embeddings (
        document_id TEXT PRIMARY KEY REFERENCES documents(id) ON DELETE CASCADE,
        model_version TEXT NOT NULL,
        dims INTEGER NOT NULL,
        vector BLOB NOT NULL
    );

    CREATE TABLE IF NOT EXISTS annotations (
        id TEXT PRIMARY KEY,
        document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        kind TEXT NOT NULL DEFAULT 'comment',
        source TEXT NOT NULL DEFAULT 'manual',
        note_id TEXT REFERENCES notes(id) ON DELETE CASCADE,
        anchor_start INTEGER NOT NULL DEFAULT 0,
        anchor_end INTEGER NOT NULL DEFAULT 0,
        anchor_exact TEXT NOT NULL DEFAULT '',
        anchor_prefix TEXT NOT NULL DEFAULT '',
        anchor_suffix TEXT NOT NULL DEFAULT '',
        created_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS annotations_document ON annotations(document_id, anchor_start);

    CREATE TABLE IF NOT EXISTS authorship_spans (
        document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        start INTEGER NOT NULL,
        end INTEGER NOT NULL,
        source TEXT NOT NULL DEFAULT 'author',
        model TEXT,
        created_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS authorship_document ON authorship_spans(document_id, start);

    CREATE TABLE IF NOT EXISTS filters (
        id TEXT PRIMARY KEY,
        scope_group_id TEXT REFERENCES groups(id) ON DELETE CASCADE,
        name TEXT NOT NULL,
        sort_index INTEGER NOT NULL DEFAULT 0,
        search_text TEXT,
        favorites_only INTEGER NOT NULL DEFAULT 0,
        modified_within REAL
    );

    CREATE TABLE IF NOT EXISTS filter_keywords (
        filter_id TEXT NOT NULL REFERENCES filters(id) ON DELETE CASCADE,
        keyword TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS filter_keywords_filter ON filter_keywords(filter_id);

    CREATE TABLE IF NOT EXISTS document_snapshots (
        document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
        created_at REAL NOT NULL,
        text TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS document_snapshots_document
        ON document_snapshots(document_id, created_at DESC);
    """
}
