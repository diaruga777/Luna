//
//  MediaSaveBacking.swift
//  LunaMediaDownload
//

import Foundation
import LunaModels
import LunaStorage

/// The save a downloaded media file belongs to.
///
/// A media file is owned by its save's row: `file_refs(file_id, save_id)` is the
/// reference that keeps it on disk, and the row going away is what frees it. So a
/// download needs that row to exist BEFORE it claims a file — a download without
/// one would write bytes no owner could ever release. Every start path resolves
/// its id here instead of falling back to a fresh UUID.
///
/// `reserveSaveAttempt` is the right primitive: it returns the existing row for a
/// URL already saved, and inserts one otherwise, under the same write lock, so two
/// download paths racing on the same URL agree on one id.
enum MediaSaveBacking {

    /// The id of the save backing `urlString`, creating the save when the URL is
    /// not in the library yet.
    static func saveID(
        for urlString: String, title: String? = nil, dateSaved: Date = Date(),
        store: SavesStore = .shared
    ) -> UUID {
        if let existing = store.item(forURLString: urlString) { return existing.id }
        return store.reserveSaveAttempt(urlString: urlString, at: dateSaved).item.id
    }
}
