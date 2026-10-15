import Foundation
import LunaModels

/// Shared, persistent indexes. Triggers also cover writes from extensions and
/// older sibling processes; reading progress never invalidates content vectors.
enum SavedLibrarySearchSchema {
    static let sql = """
        CREATE TABLE IF NOT EXISTS library_index_state (
            singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL
        );
        INSERT OR IGNORE INTO library_index_state VALUES(1, 0);
        CREATE TABLE IF NOT EXISTS library_documents (
            save_id TEXT PRIMARY KEY NOT NULL REFERENCES saves(id) ON DELETE CASCADE,
            title TEXT NOT NULL,
            body TEXT NOT NULL DEFAULT '',
            needs_backfill INTEGER NOT NULL DEFAULT 1,
            generation INTEGER NOT NULL DEFAULT 1,
            embedded_generation INTEGER NOT NULL DEFAULT 0,
            model TEXT
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS library_fts USING fts5(
            title, body, content='library_documents', content_rowid='rowid',
            tokenize='unicode61 remove_diacritics 2', prefix='2 3 4'
        );
        CREATE TABLE IF NOT EXISTS library_vectors (
            save_id TEXT NOT NULL REFERENCES library_documents(save_id) ON DELETE CASCADE,
            ordinal INTEGER NOT NULL,
            dimensions INTEGER NOT NULL,
            vector BLOB NOT NULL,
            PRIMARY KEY(save_id, ordinal)
        );
        CREATE TRIGGER IF NOT EXISTS library_document_insert AFTER INSERT ON library_documents BEGIN
            INSERT INTO library_fts(rowid, title, body) VALUES(new.rowid, new.title, new.body);
            UPDATE library_index_state SET revision=revision+1;
        END;
        CREATE TRIGGER IF NOT EXISTS library_document_delete AFTER DELETE ON library_documents BEGIN
            INSERT INTO library_fts(library_fts, rowid, title, body)
                VALUES('delete', old.rowid, old.title, old.body);
            UPDATE library_index_state SET revision=revision+1;
        END;
        CREATE TRIGGER IF NOT EXISTS library_document_update AFTER UPDATE OF title, body ON library_documents
        WHEN old.title != new.title OR old.body != new.body BEGIN
            INSERT INTO library_fts(library_fts, rowid, title, body)
                VALUES('delete', old.rowid, old.title, old.body);
            INSERT INTO library_fts(rowid, title, body) VALUES(new.rowid, new.title, new.body);
            UPDATE library_index_state SET revision=revision+1;
        END;
        CREATE TRIGGER IF NOT EXISTS library_document_revision AFTER UPDATE ON library_documents BEGIN
            UPDATE library_index_state SET revision=revision+1;
        END;
        CREATE TRIGGER IF NOT EXISTS library_save_insert AFTER INSERT ON saves BEGIN
            INSERT INTO library_documents(save_id, title) VALUES(new.id, coalesce(new.title, ''));
        END;
        CREATE TRIGGER IF NOT EXISTS library_save_title AFTER UPDATE OF title ON saves
        WHEN coalesce(old.title, '') != coalesce(new.title, '') BEGIN
            UPDATE library_documents SET title=coalesce(new.title, ''), generation=generation+1
                WHERE save_id=new.id;
        END;
        CREATE TRIGGER IF NOT EXISTS library_save_content AFTER UPDATE OF content_file_name ON saves
        WHEN old.content_file_name IS NOT new.content_file_name BEGIN
            UPDATE library_documents SET body='', needs_backfill=1, generation=generation+1
                WHERE save_id=new.id;
        END;
        INSERT OR IGNORE INTO library_documents(save_id, title)
            SELECT id, coalesce(title, '') FROM saves;
        """

    static func text(_ content: ArticleContent) -> String {
        [content.author, content.wholeText].compactMap { $0 }.joined(separator: "\n")
    }

    static func setBody(_ body: String, id: UUID, in db: SavesDatabase) throws {
        try db.run("""
            UPDATE library_documents SET body=?, needs_backfill=0,
                generation=generation + CASE WHEN body != ? THEN 1 ELSE 0 END
            WHERE save_id=? AND (body != ? OR needs_backfill != 0)
            """) {
            try $0.bind(1, body)
            try $0.bind(2, body)
            try $0.bind(3, uuid: id)
            try $0.bind(4, body)
        }
    }
}
