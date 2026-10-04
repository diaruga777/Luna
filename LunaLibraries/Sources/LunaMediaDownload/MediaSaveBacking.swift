//
//  MediaSaveBacking.swift
//  LunaMediaDownload
//

import Foundation
import LunaModels
import LunaStorage
import LunaURLClassification

/// The save a downloaded media file belongs to.
///
/// A media file is owned by its save's row: `file_refs(file_id, save_id)` is the
/// reference that keeps it on disk, and the row going away is what frees it. So a
/// download needs that row to exist BEFORE it claims a file — a download without
/// one would write bytes no owner could ever release. Every start path resolves
/// its id here instead of falling back to a fresh UUID.
///
/// A durable platform identity is parsed before the reservation when the URL
/// itself carries one. The store matches that identity against both `saves` and
/// `media_saves` inside the same write transaction, then uses the normalized URL
/// as a bounded fallback. Thus a short/wrapper URL and its permalink agree on one
/// save once either the parent or media child holds the durable identity.
enum MediaSaveBacking {

    /// The id of the save backing `urlString`, creating the save when the URL is
    /// not in the library yet.
    static func saveID(
        for urlString: String, title: String? = nil, dateSaved: Date = Date(),
        store: SavesStore = .shared
    ) -> UUID {
        // This is deliberately local parsing, not a network redirect. Opaque
        // wrapper tokens (for example Reddit `/s/`) must reach this boundary as
        // the canonical URL produced by the caller's resolver.
        let normalized = URLUnwrapper.ingestURL(from: urlString)?.absoluteString ?? urlString
        let recognized = URLBehaviorPolicy.pluginsOnly ? nil : PlatformRecognizer.recognize(normalized)
        return store.reserveSaveAttempt(
            urlString: normalized, at: dateSaved,
            platform: recognized?.platform, platformItemID: recognized?.itemID,
            recordExistingPress: false).item.id
    }
}
