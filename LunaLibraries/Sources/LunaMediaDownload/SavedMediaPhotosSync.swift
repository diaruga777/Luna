//
//  SavedMediaPhotosSync.swift
//  LunaMediaDownload
//

import Foundation

/// The Photos-save and Photos-delete calls shared by every screen that
/// promotes a locally-saved media file to a Photos asset (or removes one) —
/// the extension's single-item confirmation screen and the Downloader app's
/// saved-media carousel. Callers differ in whether they save a defensive temp
/// copy first, in `shouldMoveFile`, and in the surrounding step order (e.g.
/// where the reading-list/auto-download bookkeeping falls relative to the
/// Photos call) — those stay at the call site; only the byte-identical
/// PhotoKit + store calls live here.
public enum SavedMediaPhotosSync {
    /// Saves `fileURL` to Photos via `saver`, then flips `store`'s record for
    /// `itemID` to reference the resulting asset.
    @discardableResult
    public static func saveAndTransition(
        itemID: UUID, fileURL: URL, kind: MediaAsset.Kind, shouldMoveFile: Bool,
        saver: PhotoLibrarySaving, store: SavedMediaStore
    ) async throws -> SavedMediaItem? {
        let identifier = try await saver.save(
            fileURL: fileURL, kind: kind, shouldMoveFile: shouldMoveFile)
        return try store.transitionToPhotosReference(
            itemID, localIdentifier: identifier, kind: kind)
    }

    /// Deletes the Photos asset backing `identifier` via `saver`. A no-op
    /// when `identifier` is nil (the item was never promoted to Photos).
    /// `deleteAsset` isn't part of `PhotoLibrarySaving` (only `save` is), so
    /// this takes the concrete type, matching every existing call site.
    public static func deletePhotosAssetIfPresent(
        _ identifier: String?, saver: PhotoLibrarySaver
    ) async throws {
        guard let identifier else { return }
        try await saver.deleteAsset(localIdentifier: identifier)
    }
}
