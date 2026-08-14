//
//  MediaSaveRow.swift
//  LunaStorage
//

import Foundation
import LunaModels

/// The `media_saves` row for one downloaded-media save, and the mapping to and
/// from `SavedMediaItem`.
///
/// The storage state is stored as a discriminator plus the one name that case
/// carries, rather than as an encoded blob, so a reader that has never heard of a
/// case still sees the file name and the poster. An unrecognized discriminator
/// reads back as `.undownloaded`, which is the safe default: it says "no local
/// media", never "here is a file" for a file this binary cannot describe.
enum MediaSaveRow {

    private enum StateKind: String {
        case undownloaded, localFile, photosReference
    }

    static let selectSQL = """
        SELECT save_id, source_url_string, title, date_saved, archived_at, kind,
               storage_state, file_name, photos_identifier, thumbnail_file_name,
               platform, platform_item_id
        FROM media_saves
        """

    static let upsertSQL = """
        INSERT INTO media_saves (
            save_id, source_url_string, title, date_saved, archived_at, kind,
            storage_state, file_name, photos_identifier, thumbnail_file_name,
            platform, platform_item_id)
            SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?
            WHERE EXISTS (SELECT 1 FROM saves WHERE id = ?)
        ON CONFLICT (save_id) DO UPDATE SET
            source_url_string = excluded.source_url_string,
            title = excluded.title,
            date_saved = excluded.date_saved,
            archived_at = excluded.archived_at,
            kind = excluded.kind,
            storage_state = excluded.storage_state,
            file_name = excluded.file_name,
            photos_identifier = excluded.photos_identifier,
            thumbnail_file_name = excluded.thumbnail_file_name,
            platform = excluded.platform,
            platform_item_id = excluded.platform_item_id
        """

    /// The insert is conditional on the save existing, so a media row can never
    /// outlive — or precede — the row whose delete is meant to free its files.
    static func bindUpsert(_ item: SavedMediaItem, to statement: SavesStatement) throws {
        let state: StateKind
        var fileName: String?
        var photosIdentifier: String?
        switch item.storageState {
        case .undownloaded:
            state = .undownloaded
        case .localFile(let name):
            state = .localFile
            fileName = name
        case .photosReference(let identifier):
            state = .photosReference
            photosIdentifier = identifier
        }
        try statement.bind(1, uuid: item.id)
        try statement.bind(2, item.sourceURLString)
        try statement.bind(3, item.title)
        try statement.bind(4, date: item.dateSaved)
        try statement.bind(5, date: item.archivedAt)
        try statement.bind(6, item.kind?.rawValue)
        try statement.bind(7, state.rawValue)
        try statement.bind(8, fileName)
        try statement.bind(9, photosIdentifier)
        try statement.bind(10, item.thumbnailFileName)
        try statement.bind(11, item.platform?.rawValue)
        try statement.bind(12, item.platformItemID)
        try statement.bind(13, uuid: item.id)
    }

    static func item(from row: SavesStatement) -> SavedMediaItem? {
        guard let idString = row.string(0), let id = UUID(uuidString: idString),
              let sourceURLString = row.string(1),
              let dateSaved = row.date(3)
        else { return nil }
        let storageState: SavedMediaItem.StorageState
        switch StateKind(rawValue: row.string(6) ?? "") {
        case .localFile:
            storageState = row.string(7).map { .localFile(fileName: $0) } ?? .undownloaded
        case .photosReference:
            storageState = row.string(8).map { .photosReference(localIdentifier: $0) }
                ?? .undownloaded
        case .undownloaded, nil:
            storageState = .undownloaded
        }
        var item = SavedMediaItem(
            id: id,
            sourceURLString: sourceURLString,
            title: row.string(2),
            dateSaved: dateSaved,
            kind: row.string(5).flatMap(MediaAsset.Kind.init(rawValue:)),
            storageState: storageState,
            thumbnailFileName: row.string(9),
            platform: row.string(10).flatMap(ContentPlatform.init(rawValue:)),
            platformItemID: row.string(11))
        item.archivedAt = row.date(4)
        return item
    }
}
